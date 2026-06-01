import Foundation
import CryptoKit
import MonicaMDBX

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
            return "Android 备份"
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

public enum UnifiedVaultItemKind: String, Sendable, Equatable, CaseIterable {
    case login
    case totp
    case note
    case card
    case identity
    case passkey
    case sshKey
    case apiToken
    case wifi
    case send
    case attachmentRef

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
        case .send:
            return "安全发送"
        case .attachmentRef:
            return "附件"
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
        .send,
        .attachmentRef
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

public enum VaultCSVItemDraft: Sendable, Equatable {
    case login(LocalLoginEntryDraft)
    case note(LocalNoteEntryDraft)
    case totp(LocalTotpEntryDraft)
    case card(LocalCardEntryDraft)
    case identity(LocalIdentityEntryDraft)
    case passkey(LocalPasskeyEntryDraft)
    case sshKey(LocalSshKeyEntryDraft)
    case apiToken(LocalApiTokenEntryDraft)
    case wifi(LocalWifiEntryDraft)
    case send(LocalSendEntryDraft)

    public var kind: UnifiedVaultItemKind {
        switch self {
        case .login: return .login
        case .note: return .note
        case .totp: return .totp
        case .card: return .card
        case .identity: return .identity
        case .passkey: return .passkey
        case .sshKey: return .sshKey
        case .apiToken: return .apiToken
        case .wifi: return .wifi
        case .send: return .send
        }
    }
}

public enum VaultCSVImportIssueCode: Sendable, Equatable {
    case emptyCSV
    case missingKindColumn
    case unsupportedKind
    case missingRequiredField
    case invalidNumber
    case invalidBoolean
    case malformedCSV
}

public struct VaultCSVImportIssue: Sendable, Equatable {
    public let row: Int
    public let code: VaultCSVImportIssueCode
    public let field: String?
    public let message: String

    public init(row: Int, code: VaultCSVImportIssueCode, field: String?, message: String) {
        self.row = row
        self.code = code
        self.field = field
        self.message = message
    }
}

public struct VaultCSVImportReport: Sendable, Equatable {
    public let items: [VaultCSVItemDraft]
    public let issues: [VaultCSVImportIssue]

    public init(items: [VaultCSVItemDraft], issues: [VaultCSVImportIssue]) {
        self.items = items
        self.issues = issues
    }
}

public enum VaultCSVCodec {
    public static let columns: [String] = [
        "kind",
        "title",
        "username",
        "password",
        "url",
        "body",
        "secret",
        "issuer",
        "accountName",
        "period",
        "digits",
        "algorithm",
        "otpType",
        "counter",
        "cardholderName",
        "number",
        "expiryMonth",
        "expiryYear",
        "cvv",
        "network",
        "documentType",
        "fullName",
        "documentNumber",
        "country",
        "issueDate",
        "expiryDate",
        "relyingPartyID",
        "userHandle",
        "credentialID",
        "publicKeyCOSE",
        "privateKeyReference",
        "host",
        "publicKey",
        "passphraseHint",
        "token",
        "scopes",
        "expiresAt",
        "ssid",
        "securityType",
        "hidden",
        "maxViews",
        "notes"
    ]

    public static let headerLine = columns.joined(separator: ",")

    public static func importItems(from csv: String) -> VaultCSVImportReport {
        do {
            let rows = try parseRows(csv)
            guard let header = rows.first else {
                return VaultCSVImportReport(
                    items: [],
                    issues: [issue(row: 1, code: .emptyCSV, field: nil, detail: "CSV 文件为空")]
                )
            }
            let headerIndex = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($0.element, $0.offset) })
            guard headerIndex["kind"] != nil else {
                return VaultCSVImportReport(
                    items: [],
                    issues: [issue(row: 1, code: .missingKindColumn, field: "kind", detail: "CSV 缺少 kind 列")]
                )
            }

            var items: [VaultCSVItemDraft] = []
            var issues: [VaultCSVImportIssue] = []
            for (offset, row) in rows.dropFirst().enumerated() {
                let rowNumber = offset + 2
                if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    continue
                }
                var record = CSVRecord(row: row, headerIndex: headerIndex)
                if let item = parseItem(record: &record, rowNumber: rowNumber, issues: &issues) {
                    items.append(item)
                }
            }
            return VaultCSVImportReport(items: items, issues: issues)
        } catch {
            return VaultCSVImportReport(
                items: [],
                issues: [issue(row: 1, code: .malformedCSV, field: nil, detail: "CSV 格式无法解析")]
            )
        }
    }

    public static func exportItems(_ items: [VaultCSVItemDraft]) -> String {
        let rows = [columns] + items.map(row(for:))
        return rows.map { row in row.map(escape).joined(separator: ",") }.joined(separator: "\n")
    }

    private static func parseItem(
        record: inout CSVRecord,
        rowNumber: Int,
        issues: inout [VaultCSVImportIssue]
    ) -> VaultCSVItemDraft? {
        let kindValue = record.value("kind")
        guard let kind = UnifiedVaultItemKind(rawValue: kindValue) else {
            issues.append(issue(row: rowNumber, code: .unsupportedKind, field: "kind", detail: "不支持的条目类型"))
            return nil
        }
        let title = record.value("title")
        guard !title.isEmpty else {
            issues.append(issue(row: rowNumber, code: .missingRequiredField, field: "title", detail: "缺少必填字段 title"))
            return nil
        }

        switch kind {
        case .login:
            return .login(LocalLoginEntryDraft(
                title: title,
                username: record.value("username"),
                password: record.value("password"),
                url: record.value("url")
            ))
        case .note:
            return .note(LocalNoteEntryDraft(title: title, body: record.value("body")))
        case .totp:
            guard let period = uint32(record.value("period"), defaultValue: 30, row: rowNumber, field: "period", issues: &issues),
                  let digits = uint32(record.value("digits"), defaultValue: 6, row: rowNumber, field: "digits", issues: &issues),
                  let counter = uint64(record.value("counter"), defaultValue: 0, row: rowNumber, field: "counter", issues: &issues)
            else { return nil }
            return .totp(LocalTotpEntryDraft(
                title: title,
                secret: record.value("secret"),
                issuer: record.value("issuer"),
                accountName: record.value("accountName"),
                period: period,
                digits: digits,
                algorithm: record.value("algorithm", fallback: "SHA1"),
                otpType: record.value("otpType", fallback: "totp"),
                counter: counter
            ))
        case .card:
            return .card(LocalCardEntryDraft(
                title: title,
                cardholderName: record.value("cardholderName"),
                number: record.value("number"),
                expiryMonth: record.value("expiryMonth"),
                expiryYear: record.value("expiryYear"),
                cvv: record.value("cvv"),
                issuer: record.value("issuer"),
                network: record.value("network"),
                notes: record.value("notes")
            ))
        case .identity:
            return .identity(LocalIdentityEntryDraft(
                title: title,
                documentType: record.value("documentType"),
                fullName: record.value("fullName"),
                documentNumber: record.value("documentNumber"),
                issuer: record.value("issuer"),
                country: record.value("country"),
                issueDate: record.value("issueDate"),
                expiryDate: record.value("expiryDate"),
                notes: record.value("notes")
            ))
        case .passkey:
            return .passkey(LocalPasskeyEntryDraft(
                title: title,
                relyingPartyID: record.value("relyingPartyID"),
                username: record.value("username"),
                userHandle: record.value("userHandle"),
                credentialID: record.value("credentialID"),
                publicKeyCOSE: record.value("publicKeyCOSE"),
                privateKeyReference: record.value("privateKeyReference"),
                notes: record.value("notes")
            ))
        case .sshKey:
            return .sshKey(LocalSshKeyEntryDraft(
                title: title,
                username: record.value("username"),
                host: record.value("host"),
                publicKey: record.value("publicKey"),
                privateKeyReference: record.value("privateKeyReference"),
                passphraseHint: record.value("passphraseHint"),
                notes: record.value("notes")
            ))
        case .apiToken:
            return .apiToken(LocalApiTokenEntryDraft(
                title: title,
                issuer: record.value("issuer"),
                accountName: record.value("accountName"),
                token: record.value("token"),
                scopes: record.value("scopes"),
                expiresAt: record.value("expiresAt"),
                notes: record.value("notes")
            ))
        case .wifi:
            guard let hidden = bool(record.value("hidden"), defaultValue: false, row: rowNumber, field: "hidden", issues: &issues) else {
                return nil
            }
            return .wifi(LocalWifiEntryDraft(
                title: title,
                ssid: record.value("ssid"),
                securityType: record.value("securityType"),
                password: record.value("password"),
                hidden: hidden,
                notes: record.value("notes")
            ))
        case .send:
            guard let maxViews = int(record.value("maxViews"), defaultValue: 1, row: rowNumber, field: "maxViews", issues: &issues) else {
                return nil
            }
            return .send(LocalSendEntryDraft(
                title: title,
                body: record.value("body"),
                expiresAt: record.value("expiresAt"),
                maxViews: maxViews,
                notes: record.value("notes")
            ))
        case .attachmentRef:
            issues.append(issue(row: rowNumber, code: .unsupportedKind, field: "kind", detail: "CSV 暂不导入附件内容"))
            return nil
        }
    }

    private static func row(for item: VaultCSVItemDraft) -> [String] {
        var values = Dictionary(uniqueKeysWithValues: columns.map { ($0, "") })
        values["kind"] = item.kind.rawValue
        switch item {
        case .login(let draft):
            values["title"] = draft.title
            values["username"] = draft.username
            values["password"] = draft.password
            values["url"] = draft.url
        case .note(let draft):
            values["title"] = draft.title
            values["body"] = draft.body
        case .totp(let draft):
            values["title"] = draft.title
            values["secret"] = draft.secret
            values["issuer"] = draft.issuer
            values["accountName"] = draft.accountName
            values["period"] = String(draft.period)
            values["digits"] = String(draft.digits)
            values["algorithm"] = draft.algorithm
            values["otpType"] = draft.otpType
            values["counter"] = String(draft.counter)
        case .card(let draft):
            values["title"] = draft.title
            values["cardholderName"] = draft.cardholderName
            values["number"] = draft.number
            values["expiryMonth"] = draft.expiryMonth
            values["expiryYear"] = draft.expiryYear
            values["cvv"] = draft.cvv
            values["issuer"] = draft.issuer
            values["network"] = draft.network
            values["notes"] = draft.notes
        case .identity(let draft):
            values["title"] = draft.title
            values["documentType"] = draft.documentType
            values["fullName"] = draft.fullName
            values["documentNumber"] = draft.documentNumber
            values["issuer"] = draft.issuer
            values["country"] = draft.country
            values["issueDate"] = draft.issueDate
            values["expiryDate"] = draft.expiryDate
            values["notes"] = draft.notes
        case .passkey(let draft):
            values["title"] = draft.title
            values["username"] = draft.username
            values["relyingPartyID"] = draft.relyingPartyID
            values["userHandle"] = draft.userHandle
            values["credentialID"] = draft.credentialID
            values["publicKeyCOSE"] = draft.publicKeyCOSE
            values["privateKeyReference"] = draft.privateKeyReference
            values["notes"] = draft.notes
        case .sshKey(let draft):
            values["title"] = draft.title
            values["username"] = draft.username
            values["host"] = draft.host
            values["publicKey"] = draft.publicKey
            values["privateKeyReference"] = draft.privateKeyReference
            values["passphraseHint"] = draft.passphraseHint
            values["notes"] = draft.notes
        case .apiToken(let draft):
            values["title"] = draft.title
            values["issuer"] = draft.issuer
            values["accountName"] = draft.accountName
            values["token"] = draft.token
            values["scopes"] = draft.scopes
            values["expiresAt"] = draft.expiresAt
            values["notes"] = draft.notes
        case .wifi(let draft):
            values["title"] = draft.title
            values["ssid"] = draft.ssid
            values["securityType"] = draft.securityType
            values["password"] = draft.password
            values["hidden"] = String(draft.hidden)
            values["notes"] = draft.notes
        case .send(let draft):
            values["title"] = draft.title
            values["body"] = draft.body
            values["expiresAt"] = draft.expiresAt
            values["maxViews"] = String(draft.maxViews)
            values["notes"] = draft.notes
        }
        return columns.map { values[$0] ?? "" }
    }

    private static func parseRows(_ csv: String) throws -> [[String]] {
        let input = csv.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return [] }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]
            if isQuoted {
                if character == "\"" {
                    let next = input.index(after: index)
                    if next < input.endIndex, input[next] == "\"" {
                        field.append("\"")
                        index = input.index(after: next)
                    } else {
                        isQuoted = false
                        index = next
                    }
                } else {
                    field.append(character)
                    index = input.index(after: index)
                }
            } else {
                switch character {
                case "\"":
                    isQuoted = true
                    index = input.index(after: index)
                case ",":
                    row.append(normalizedField(field))
                    field = ""
                    index = input.index(after: index)
                case "\n":
                    row.append(normalizedField(field))
                    rows.append(row)
                    row = []
                    field = ""
                    index = input.index(after: index)
                case "\r":
                    index = input.index(after: index)
                default:
                    field.append(character)
                    index = input.index(after: index)
                }
            }
        }
        if isQuoted { throw LocalVaultRepositoryError.vaultUnavailable }
        row.append(normalizedField(field))
        rows.append(row)
        return rows
    }

    private static func normalizedField(_ field: String) -> String {
        field.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\n") || value.contains("\"") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private static func uint32(
        _ value: String,
        defaultValue: UInt32,
        row: Int,
        field: String,
        issues: inout [VaultCSVImportIssue]
    ) -> UInt32? {
        guard !value.isEmpty else { return defaultValue }
        guard let parsed = UInt32(value) else {
            issues.append(issue(row: row, code: .invalidNumber, field: field, detail: "数字字段格式错误"))
            return nil
        }
        return parsed
    }

    private static func uint64(
        _ value: String,
        defaultValue: UInt64,
        row: Int,
        field: String,
        issues: inout [VaultCSVImportIssue]
    ) -> UInt64? {
        guard !value.isEmpty else { return defaultValue }
        guard let parsed = UInt64(value) else {
            issues.append(issue(row: row, code: .invalidNumber, field: field, detail: "数字字段格式错误"))
            return nil
        }
        return parsed
    }

    private static func int(
        _ value: String,
        defaultValue: Int,
        row: Int,
        field: String,
        issues: inout [VaultCSVImportIssue]
    ) -> Int? {
        guard !value.isEmpty else { return defaultValue }
        guard let parsed = Int(value) else {
            issues.append(issue(row: row, code: .invalidNumber, field: field, detail: "数字字段格式错误"))
            return nil
        }
        return parsed
    }

    private static func bool(
        _ value: String,
        defaultValue: Bool,
        row: Int,
        field: String,
        issues: inout [VaultCSVImportIssue]
    ) -> Bool? {
        guard !value.isEmpty else { return defaultValue }
        switch value.lowercased() {
        case "true", "1", "yes", "y": return true
        case "false", "0", "no", "n": return false
        default:
            issues.append(issue(row: row, code: .invalidBoolean, field: field, detail: "布尔字段格式错误"))
            return nil
        }
    }

    private static func issue(row: Int, code: VaultCSVImportIssueCode, field: String?, detail: String) -> VaultCSVImportIssue {
        let fieldText = field.map { " 字段 \($0)" } ?? ""
        return VaultCSVImportIssue(row: row, code: code, field: field, message: "第 \(row) 行\(fieldText)：\(detail)")
    }
}

private struct CSVRecord {
    let row: [String]
    let headerIndex: [String: Int]

    func value(_ field: String, fallback: String = "") -> String {
        guard let index = headerIndex[field], index < row.count else {
            return fallback
        }
        let value = row[index]
        return value.isEmpty ? fallback : value
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

public enum ParityFeatureFlag: String, Sendable, Equatable, CaseIterable {
    case passwords
    case totp
    case notes
    case wallet
    case identities
    case autofill
    case backup
    case keepass
    case bitwarden
    case passkeys
    case attachments
    case settings

    public static let phaseOneEnabled: [ParityFeatureFlag] = [
        .passwords,
        .totp,
        .notes,
        .wallet,
        .identities,
        .settings
    ]

    public static let phaseTwoEnabled: [ParityFeatureFlag] = phaseOneEnabled + [
        .autofill
    ]

    public var isEnabledInPhaseOne: Bool {
        Self.phaseOneEnabled.contains(self)
    }

    public var isEnabledInPhaseTwo: Bool {
        Self.phaseTwoEnabled.contains(self)
    }

    public var disabledReason: String? {
        guard !isEnabledInPhaseTwo else {
            return nil
        }
        switch self {
        case .backup:
            return "第三阶段接入 Android 备份兼容。"
        case .keepass:
            return "第四阶段接入 KDBX 兼容。"
        case .bitwarden:
            return "后续阶段接入 Bitwarden 多真源。"
        case .passkeys:
            return "后续阶段接入 iOS AuthenticationServices。"
        case .attachments:
            return "后续阶段接入附件。"
        case .passwords, .totp, .notes, .wallet, .identities, .autofill, .settings:
            return nil
        }
    }
}

public enum LocalVaultState: Sendable, Equatable {
    case unlocked
    case locked
}

public enum LocalVaultRepositoryError: Error, Sendable, Equatable, LocalizedError {
    case emptyVaultName
    case emptyPassword
    case emptySecurityKeyMaterial
    case emptyProjectTitle
    case emptyEntryTitle
    case vaultUnavailable
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
        case .emptyProjectTitle:
            return "项目标题不能为空。"
        case .emptyEntryTitle:
            return "条目标题不能为空。"
        case .vaultUnavailable:
            return "保险库会话已不可用。"
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

    func resetMasterPassword(
        in handle: LocalVaultHandle,
        newPassword: String
    ) throws

    func closeVault(_ handle: LocalVaultHandle)

    func createProject(
        in handle: LocalVaultHandle,
        title: String
    ) throws -> LocalVaultProject

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
        storageMode: String
    ) throws -> LocalAttachmentMetadata

    func listAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalAttachmentMetadata]

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
}

public extension LocalVaultEngine {
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

    func createSendEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func listSendEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSendEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func updateSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func setSendEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSendEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func deleteSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func listDeletedSendEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSendEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func restoreSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSendEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }

    func createAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, entryID: String?, fileName: String, mediaType: String, originalSize: Int64, storedSize: Int64, contentHash: String, storageMode: String) throws -> LocalAttachmentMetadata { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
    func listAttachmentMetadata(in handle: LocalVaultHandle, projectID: String) throws -> [LocalAttachmentMetadata] { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
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

public struct LocalLoginEntryDraft: Sendable, Equatable {
    public let title: String
    public let username: String
    public let password: String
    public let url: String

    public init(
        title: String,
        username: String,
        password: String,
        url: String
    ) {
        self.title = title
        self.username = username
        self.password = password
        self.url = url
    }
}

public struct LocalLoginEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let username: String
    public let password: String
    public let url: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        username: String,
        password: String,
        url: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.username = username
        self.password = password
        self.url = url
        self.favorite = favorite
    }
}

public struct LocalNoteEntryDraft: Sendable, Equatable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public struct LocalNoteEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let body: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        body: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.body = body
        self.favorite = favorite
    }
}

public struct LocalTotpEntryDraft: Sendable, Equatable {
    public let title: String
    public let secret: String
    public let issuer: String
    public let accountName: String
    public let period: UInt32
    public let digits: UInt32
    public let algorithm: String
    public let otpType: String
    public let counter: UInt64

    public init(
        title: String,
        secret: String,
        issuer: String,
        accountName: String,
        period: UInt32,
        digits: UInt32,
        algorithm: String,
        otpType: String,
        counter: UInt64
    ) {
        self.title = title
        self.secret = secret
        self.issuer = issuer
        self.accountName = accountName
        self.period = period
        self.digits = digits
        self.algorithm = algorithm
        self.otpType = otpType
        self.counter = counter
    }
}

public struct LocalTotpEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let secret: String
    public let issuer: String
    public let accountName: String
    public let period: UInt32
    public let digits: UInt32
    public let algorithm: String
    public let otpType: String
    public let counter: UInt64
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        secret: String,
        issuer: String,
        accountName: String,
        period: UInt32,
        digits: UInt32,
        algorithm: String,
        otpType: String,
        counter: UInt64,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.secret = secret
        self.issuer = issuer
        self.accountName = accountName
        self.period = period
        self.digits = digits
        self.algorithm = algorithm
        self.otpType = otpType
        self.counter = counter
        self.favorite = favorite
    }
}

public struct LocalCardEntryDraft: Sendable, Equatable {
    public let title: String
    public let cardholderName: String
    public let number: String
    public let expiryMonth: String
    public let expiryYear: String
    public let cvv: String
    public let issuer: String
    public let network: String
    public let notes: String

    public init(
        title: String,
        cardholderName: String,
        number: String,
        expiryMonth: String,
        expiryYear: String,
        cvv: String,
        issuer: String,
        network: String,
        notes: String
    ) {
        self.title = title
        self.cardholderName = cardholderName
        self.number = number
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear
        self.cvv = cvv
        self.issuer = issuer
        self.network = network
        self.notes = notes
    }
}

public struct LocalCardEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let cardholderName: String
    public let number: String
    public let expiryMonth: String
    public let expiryYear: String
    public let cvv: String
    public let issuer: String
    public let network: String
    public let notes: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        cardholderName: String,
        number: String,
        expiryMonth: String,
        expiryYear: String,
        cvv: String,
        issuer: String,
        network: String,
        notes: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.cardholderName = cardholderName
        self.number = number
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear
        self.cvv = cvv
        self.issuer = issuer
        self.network = network
        self.notes = notes
        self.favorite = favorite
    }
}

public struct LocalIdentityEntryDraft: Sendable, Equatable {
    public let title: String
    public let documentType: String
    public let fullName: String
    public let documentNumber: String
    public let issuer: String
    public let country: String
    public let issueDate: String
    public let expiryDate: String
    public let notes: String

    public init(
        title: String,
        documentType: String,
        fullName: String,
        documentNumber: String,
        issuer: String,
        country: String,
        issueDate: String,
        expiryDate: String,
        notes: String
    ) {
        self.title = title
        self.documentType = documentType
        self.fullName = fullName
        self.documentNumber = documentNumber
        self.issuer = issuer
        self.country = country
        self.issueDate = issueDate
        self.expiryDate = expiryDate
        self.notes = notes
    }
}

public struct LocalIdentityEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let documentType: String
    public let fullName: String
    public let documentNumber: String
    public let issuer: String
    public let country: String
    public let issueDate: String
    public let expiryDate: String
    public let notes: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        documentType: String,
        fullName: String,
        documentNumber: String,
        issuer: String,
        country: String,
        issueDate: String,
        expiryDate: String,
        notes: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.documentType = documentType
        self.fullName = fullName
        self.documentNumber = documentNumber
        self.issuer = issuer
        self.country = country
        self.issueDate = issueDate
        self.expiryDate = expiryDate
        self.notes = notes
        self.favorite = favorite
    }
}

public struct LocalPasskeyEntryDraft: Sendable, Equatable {
    public let title: String
    public let relyingPartyID: String
    public let username: String
    public let userHandle: String
    public let credentialID: String
    public let publicKeyCOSE: String
    public let privateKeyReference: String
    public let notes: String

    public init(
        title: String,
        relyingPartyID: String,
        username: String,
        userHandle: String,
        credentialID: String,
        publicKeyCOSE: String,
        privateKeyReference: String,
        notes: String
    ) {
        self.title = title
        self.relyingPartyID = relyingPartyID
        self.username = username
        self.userHandle = userHandle
        self.credentialID = credentialID
        self.publicKeyCOSE = publicKeyCOSE
        self.privateKeyReference = privateKeyReference
        self.notes = notes
    }
}

public struct LocalPasskeyEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let relyingPartyID: String
    public let username: String
    public let userHandle: String
    public let credentialID: String
    public let publicKeyCOSE: String
    public let privateKeyReference: String
    public let notes: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        relyingPartyID: String,
        username: String,
        userHandle: String,
        credentialID: String,
        publicKeyCOSE: String,
        privateKeyReference: String,
        notes: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.relyingPartyID = relyingPartyID
        self.username = username
        self.userHandle = userHandle
        self.credentialID = credentialID
        self.publicKeyCOSE = publicKeyCOSE
        self.privateKeyReference = privateKeyReference
        self.notes = notes
        self.favorite = favorite
    }
}

public struct LocalSshKeyEntryDraft: Sendable, Equatable {
    public let title: String
    public let username: String
    public let host: String
    public let publicKey: String
    public let privateKeyReference: String
    public let passphraseHint: String
    public let notes: String

    public init(
        title: String,
        username: String,
        host: String,
        publicKey: String,
        privateKeyReference: String,
        passphraseHint: String,
        notes: String
    ) {
        self.title = title
        self.username = username
        self.host = host
        self.publicKey = publicKey
        self.privateKeyReference = privateKeyReference
        self.passphraseHint = passphraseHint
        self.notes = notes
    }
}

public struct LocalSshKeyEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let username: String
    public let host: String
    public let publicKey: String
    public let privateKeyReference: String
    public let passphraseHint: String
    public let notes: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        username: String,
        host: String,
        publicKey: String,
        privateKeyReference: String,
        passphraseHint: String,
        notes: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.username = username
        self.host = host
        self.publicKey = publicKey
        self.privateKeyReference = privateKeyReference
        self.passphraseHint = passphraseHint
        self.notes = notes
        self.favorite = favorite
    }
}

public struct LocalApiTokenEntryDraft: Sendable, Equatable {
    public let title: String
    public let issuer: String
    public let accountName: String
    public let token: String
    public let scopes: String
    public let expiresAt: String
    public let notes: String

    public init(
        title: String,
        issuer: String,
        accountName: String,
        token: String,
        scopes: String,
        expiresAt: String,
        notes: String
    ) {
        self.title = title
        self.issuer = issuer
        self.accountName = accountName
        self.token = token
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.notes = notes
    }
}

public struct LocalApiTokenEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let issuer: String
    public let accountName: String
    public let token: String
    public let scopes: String
    public let expiresAt: String
    public let notes: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        issuer: String,
        accountName: String,
        token: String,
        scopes: String,
        expiresAt: String,
        notes: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.issuer = issuer
        self.accountName = accountName
        self.token = token
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.notes = notes
        self.favorite = favorite
    }
}

public struct LocalWifiEntryDraft: Sendable, Equatable {
    public let title: String
    public let ssid: String
    public let securityType: String
    public let password: String
    public let hidden: Bool
    public let notes: String

    public init(
        title: String,
        ssid: String,
        securityType: String,
        password: String,
        hidden: Bool,
        notes: String
    ) {
        self.title = title
        self.ssid = ssid
        self.securityType = securityType
        self.password = password
        self.hidden = hidden
        self.notes = notes
    }
}

public struct LocalWifiEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let ssid: String
    public let securityType: String
    public let password: String
    public let hidden: Bool
    public let notes: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        ssid: String,
        securityType: String,
        password: String,
        hidden: Bool,
        notes: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.ssid = ssid
        self.securityType = securityType
        self.password = password
        self.hidden = hidden
        self.notes = notes
        self.favorite = favorite
    }
}

public struct LocalSendEntryDraft: Sendable, Equatable {
    public let title: String
    public let body: String
    public let expiresAt: String
    public let maxViews: Int
    public let notes: String

    public init(
        title: String,
        body: String,
        expiresAt: String,
        maxViews: Int,
        notes: String
    ) {
        self.title = title
        self.body = body
        self.expiresAt = expiresAt
        self.maxViews = maxViews
        self.notes = notes
    }
}

public struct LocalSendEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let body: String
    public let expiresAt: String
    public let maxViews: Int
    public let notes: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        body: String,
        expiresAt: String,
        maxViews: Int,
        notes: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.body = body
        self.expiresAt = expiresAt
        self.maxViews = maxViews
        self.notes = notes
        self.favorite = favorite
    }
}

public struct LocalAttachmentMetadata: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let entryID: String?
    public let fileName: String
    public let mediaType: String
    public let originalSize: Int64
    public let storedSize: Int64
    public let contentHash: String
    public let storageMode: String
    public let deleted: Bool

    public init(
        id: String,
        projectID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        deleted: Bool
    ) {
        self.id = id
        self.projectID = projectID
        self.entryID = entryID
        self.fileName = fileName
        self.mediaType = mediaType
        self.originalSize = originalSize
        self.storedSize = storedSize
        self.contentHash = contentHash
        self.storageMode = storageMode
        self.deleted = deleted
    }
}

public struct AutoFillEncryptedIndexRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let nonce: Data
    public let ciphertext: Data
    public let authenticationTag: Data

    public init(
        id: String,
        nonce: Data,
        ciphertext: Data,
        authenticationTag: Data
    ) {
        self.id = id
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.authenticationTag = authenticationTag
    }
}

public struct AutoFillCredentialIndexRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let username: String
    public let serviceIdentifiers: [String]

    public init(
        id: String,
        title: String,
        username: String,
        serviceIdentifiers: [String]
    ) {
        self.id = id
        self.title = title
        self.username = username
        self.serviceIdentifiers = serviceIdentifiers
    }
}

public struct AutoFillCredentialSecretRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let username: String
    public let password: String

    public init(id: String, username: String, password: String) {
        self.id = id
        self.username = username
        self.password = password
    }
}

public enum AutoFillEncryptedIndexCodecError: Error, Sendable, Equatable, LocalizedError {
    case invalidKeyLength(expected: Int, actual: Int)
    case vaultIdentifierMismatch(expected: String, actual: String)
    case keyIdentifierMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength(let expected, let actual):
            return "自动填充索引密钥必须是 \(expected) 字节，当前为 \(actual) 字节。"
        case .vaultIdentifierMismatch(let expected, let actual):
            return "自动填充索引保险库不匹配。预期 \(expected)，当前 \(actual)。"
        case .keyIdentifierMismatch(let expected, let actual):
            return "自动填充索引密钥不匹配。预期 \(expected)，当前 \(actual)。"
        }
    }
}

public struct AutoFillIndexEncryptionKey: Sendable, Equatable {
    public static let requiredByteCount = 32

    public let rawValue: Data

    public init(rawValue: Data) throws {
        guard rawValue.count == AutoFillIndexEncryptionKey.requiredByteCount else {
            throw AutoFillEncryptedIndexCodecError.invalidKeyLength(
                expected: AutoFillIndexEncryptionKey.requiredByteCount,
                actual: rawValue.count
            )
        }

        self.rawValue = rawValue
    }
}

public struct AutoFillEncryptedIndexCodec: Sendable {
    public init() {}

    public func encrypt(
        _ records: [AutoFillCredentialIndexRecord],
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        key: AutoFillIndexEncryptionKey
    ) throws -> AutoFillEncryptedIndex {
        let symmetricKey = SymmetricKey(data: key.rawValue)
        let encryptedRecords = try records.map { record in
            let plaintext = try Self.payloadEncoder.encode(record)
            let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey)
            return AutoFillEncryptedIndexRecord(
                id: record.id,
                nonce: Data(sealedBox.nonce),
                ciphertext: sealedBox.ciphertext,
                authenticationTag: sealedBox.tag
            )
        }

        return AutoFillEncryptedIndex(
            vaultID: vaultID,
            keyIdentifier: keyIdentifier,
            updatedAt: updatedAt,
            records: encryptedRecords
        )
    }

    public func decrypt(
        _ index: AutoFillEncryptedIndex,
        key: AutoFillIndexEncryptionKey
    ) throws -> [AutoFillCredentialIndexRecord] {
        let symmetricKey = SymmetricKey(data: key.rawValue)
        return try index.records.map { record in
            let nonce = try AES.GCM.Nonce(data: record.nonce)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: record.ciphertext,
                tag: record.authenticationTag
            )
            let plaintext = try AES.GCM.open(sealedBox, using: symmetricKey)
            return try Self.payloadDecoder.decode(
                AutoFillCredentialIndexRecord.self,
                from: plaintext
            )
        }
    }

    private static let payloadEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let payloadDecoder = JSONDecoder()
}

public struct AutoFillEncryptedIndex: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let vaultID: String
    public let keyIdentifier: String
    public let updatedAt: Date
    public let records: [AutoFillEncryptedIndexRecord]

    public init(
        schemaVersion: Int = AutoFillEncryptedIndex.currentSchemaVersion,
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        records: [AutoFillEncryptedIndexRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.vaultID = vaultID
        self.keyIdentifier = keyIdentifier
        self.updatedAt = updatedAt
        self.records = records
    }
}

public struct AutoFillEncryptedCredentialSecretRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let nonce: Data
    public let ciphertext: Data
    public let authenticationTag: Data

    public init(
        id: String,
        nonce: Data,
        ciphertext: Data,
        authenticationTag: Data
    ) {
        self.id = id
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.authenticationTag = authenticationTag
    }
}

public struct AutoFillCredentialSecretSnapshot: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let vaultID: String
    public let keyIdentifier: String
    public let updatedAt: Date
    public let records: [AutoFillEncryptedCredentialSecretRecord]

    public init(
        schemaVersion: Int = AutoFillCredentialSecretSnapshot.currentSchemaVersion,
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        records: [AutoFillEncryptedCredentialSecretRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.vaultID = vaultID
        self.keyIdentifier = keyIdentifier
        self.updatedAt = updatedAt
        self.records = records
    }
}

public protocol AutoFillEncryptedIndexStore: Sendable {
    func save(_ index: AutoFillEncryptedIndex) throws
    func load() throws -> AutoFillEncryptedIndex?
    func delete() throws
}

public protocol AutoFillCredentialSecretStore: Sendable {
    func save(_ snapshot: AutoFillCredentialSecretSnapshot) throws
    func load() throws -> AutoFillCredentialSecretSnapshot?
    func delete() throws
}

public struct AutoFillUnlockedCredentialIndex: Sendable, Equatable {
    public let vaultID: String
    public let keyIdentifier: String
    public let updatedAt: Date
    public let records: [AutoFillCredentialIndexRecord]

    public init(
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        records: [AutoFillCredentialIndexRecord]
    ) {
        self.vaultID = vaultID
        self.keyIdentifier = keyIdentifier
        self.updatedAt = updatedAt
        self.records = records
    }

    public func search(_ query: String) -> [AutoFillCredentialIndexRecord] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else {
            return records
        }

        return records.filter { record in
            record.title.localizedCaseInsensitiveContains(normalizedQuery)
                || record.username.localizedCaseInsensitiveContains(normalizedQuery)
                || record.serviceIdentifiers.contains {
                    $0.localizedCaseInsensitiveContains(normalizedQuery)
                }
        }
    }

    public func records(
        matchingServiceIdentifier serviceIdentifier: String
    ) -> [AutoFillCredentialIndexRecord] {
        guard let requestedHost = Self.normalizedHost(from: serviceIdentifier) else {
            return []
        }

        return records.filter { record in
            record.serviceIdentifiers.contains { candidate in
                guard let candidateHost = Self.normalizedHost(from: candidate) else {
                    return false
                }
                return requestedHost == candidateHost
                    || requestedHost.hasSuffix(".\(candidateHost)")
                    || candidateHost.hasSuffix(".\(requestedHost)")
            }
        }
    }

    private static func normalizedHost(from serviceIdentifier: String) -> String? {
        let trimmed = serviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let host = URL(string: trimmed)?.host(), !host.isEmpty {
            return host.lowercased()
        }

        if let host = URL(string: "https://\(trimmed)")?.host(), !host.isEmpty {
            return host.lowercased()
        }

        return nil
    }
}

public struct AutoFillCredentialIndexUnlocker: Sendable {
    private let codec: AutoFillEncryptedIndexCodec

    public init(codec: AutoFillEncryptedIndexCodec = AutoFillEncryptedIndexCodec()) {
        self.codec = codec
    }

    public func unlock(
        _ index: AutoFillEncryptedIndex,
        vaultID: String,
        keyIdentifier: String,
        key: AutoFillIndexEncryptionKey
    ) throws -> AutoFillUnlockedCredentialIndex {
        guard index.vaultID == vaultID else {
            throw AutoFillEncryptedIndexCodecError.vaultIdentifierMismatch(
                expected: vaultID,
                actual: index.vaultID
            )
        }
        guard index.keyIdentifier == keyIdentifier else {
            throw AutoFillEncryptedIndexCodecError.keyIdentifierMismatch(
                expected: keyIdentifier,
                actual: index.keyIdentifier
            )
        }

        return AutoFillUnlockedCredentialIndex(
            vaultID: index.vaultID,
            keyIdentifier: index.keyIdentifier,
            updatedAt: index.updatedAt,
            records: try codec.decrypt(index, key: key)
        )
    }
}

public struct AutoFillCredentialSecretCodec: Sendable {
    public init() {}

    public func encrypt(
        _ records: [AutoFillCredentialSecretRecord],
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        key: AutoFillIndexEncryptionKey
    ) throws -> AutoFillCredentialSecretSnapshot {
        let symmetricKey = SymmetricKey(data: key.rawValue)
        let encryptedRecords = try records.map { record in
            let plaintext = try Self.payloadEncoder.encode(record)
            let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey)
            return AutoFillEncryptedCredentialSecretRecord(
                id: record.id,
                nonce: Data(sealedBox.nonce),
                ciphertext: sealedBox.ciphertext,
                authenticationTag: sealedBox.tag
            )
        }

        return AutoFillCredentialSecretSnapshot(
            vaultID: vaultID,
            keyIdentifier: keyIdentifier,
            updatedAt: updatedAt,
            records: encryptedRecords
        )
    }

    public func decrypt(
        _ snapshot: AutoFillCredentialSecretSnapshot,
        key: AutoFillIndexEncryptionKey
    ) throws -> [AutoFillCredentialSecretRecord] {
        let symmetricKey = SymmetricKey(data: key.rawValue)
        return try snapshot.records.map { record in
            let nonce = try AES.GCM.Nonce(data: record.nonce)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: record.ciphertext,
                tag: record.authenticationTag
            )
            let plaintext = try AES.GCM.open(sealedBox, using: symmetricKey)
            return try Self.payloadDecoder.decode(
                AutoFillCredentialSecretRecord.self,
                from: plaintext
            )
        }
    }

    private static let payloadEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let payloadDecoder = JSONDecoder()
}

public struct AutoFillUnlockedCredentialSecretSnapshot: Sendable, Equatable {
    public let vaultID: String
    public let keyIdentifier: String
    public let updatedAt: Date
    public let records: [AutoFillCredentialSecretRecord]

    public init(
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        records: [AutoFillCredentialSecretRecord]
    ) {
        self.vaultID = vaultID
        self.keyIdentifier = keyIdentifier
        self.updatedAt = updatedAt
        self.records = records
    }

    public func secret(id: String) -> AutoFillCredentialSecretRecord? {
        records.first { $0.id == id }
    }
}

public struct AutoFillCredentialSecretUnlocker: Sendable {
    private let codec: AutoFillCredentialSecretCodec

    public init(codec: AutoFillCredentialSecretCodec = AutoFillCredentialSecretCodec()) {
        self.codec = codec
    }

    public func unlock(
        _ snapshot: AutoFillCredentialSecretSnapshot,
        vaultID: String,
        keyIdentifier: String,
        key: AutoFillIndexEncryptionKey
    ) throws -> AutoFillUnlockedCredentialSecretSnapshot {
        guard snapshot.vaultID == vaultID else {
            throw AutoFillEncryptedIndexCodecError.vaultIdentifierMismatch(
                expected: vaultID,
                actual: snapshot.vaultID
            )
        }
        guard snapshot.keyIdentifier == keyIdentifier else {
            throw AutoFillEncryptedIndexCodecError.keyIdentifierMismatch(
                expected: keyIdentifier,
                actual: snapshot.keyIdentifier
            )
        }

        return AutoFillUnlockedCredentialSecretSnapshot(
            vaultID: snapshot.vaultID,
            keyIdentifier: snapshot.keyIdentifier,
            updatedAt: snapshot.updatedAt,
            records: try codec.decrypt(snapshot, key: key)
        )
    }
}

public enum AutoFillCredentialResolverError: Error, Sendable, Equatable, LocalizedError {
    case credentialUnavailable
    case credentialSecretUnavailable

    public var errorDescription: String? {
        switch self {
        case .credentialUnavailable:
            return "自动填充凭据不可用。"
        case .credentialSecretUnavailable:
            return "自动填充凭据密钥不可用。"
        }
    }
}

public struct AutoFillCredentialResolver: Sendable {
    public let index: AutoFillUnlockedCredentialIndex
    public let secrets: AutoFillUnlockedCredentialSecretSnapshot

    public init(
        index: AutoFillUnlockedCredentialIndex,
        secrets: AutoFillUnlockedCredentialSecretSnapshot
    ) {
        self.index = index
        self.secrets = secrets
    }

    public func records(
        matchingServiceIdentifiers serviceIdentifiers: [String]
    ) -> [AutoFillCredentialIndexRecord] {
        guard !serviceIdentifiers.isEmpty else {
            return index.records
        }

        var matchedRecords: [AutoFillCredentialIndexRecord] = []
        for serviceIdentifier in serviceIdentifiers {
            matchedRecords.append(
                contentsOf: index.records(
                    matchingServiceIdentifier: serviceIdentifier
                )
            )
        }

        return deduplicated(matchedRecords)
    }

    public func search(
        _ query: String,
        within records: [AutoFillCredentialIndexRecord]
    ) -> [AutoFillCredentialIndexRecord] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return records
        }

        let recordIDs = Set(records.map(\.id))
        return index.search(trimmedQuery).filter { recordIDs.contains($0.id) }
    }

    public func credential(
        recordIdentifier: String
    ) throws -> AutoFillCredentialSecretRecord {
        let trimmedIdentifier = recordIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard index.records.contains(where: { $0.id == trimmedIdentifier }) else {
            throw AutoFillCredentialResolverError.credentialUnavailable
        }
        guard let secret = secrets.secret(id: trimmedIdentifier) else {
            throw AutoFillCredentialResolverError.credentialSecretUnavailable
        }
        return secret
    }

    public func credential(
        for record: AutoFillCredentialIndexRecord
    ) throws -> AutoFillCredentialSecretRecord {
        try credential(recordIdentifier: record.id)
    }

    private func deduplicated(
        _ records: [AutoFillCredentialIndexRecord]
    ) -> [AutoFillCredentialIndexRecord] {
        var seen = Set<String>()
        return records.filter { record in
            seen.insert(record.id).inserted
        }
    }
}

public struct FileAutoFillEncryptedIndexStore: AutoFillEncryptedIndexStore {
    public static let indexFileName = "autofill-index-v1.json"

    public let appGroupContainerURL: URL
    public let indexFileURL: URL

    public init(appGroupContainerURL: URL) {
        self.appGroupContainerURL = appGroupContainerURL
        self.indexFileURL = appGroupContainerURL.appendingPathComponent(
            FileAutoFillEncryptedIndexStore.indexFileName,
            isDirectory: false
        )
    }

    public func save(_ index: AutoFillEncryptedIndex) throws {
        try FileManager.default.createDirectory(
            at: appGroupContainerURL,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: indexFileURL, options: fileWritingOptions)
    }

    public func load() throws -> AutoFillEncryptedIndex? {
        guard FileManager.default.fileExists(atPath: indexFileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: indexFileURL)
        return try JSONDecoder().decode(AutoFillEncryptedIndex.self, from: data)
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: indexFileURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: indexFileURL)
    }

    private var fileWritingOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }
}

public struct FileAutoFillCredentialSecretStore: AutoFillCredentialSecretStore {
    public static let secretFileName = "autofill-secrets-v1.json"

    public let appGroupContainerURL: URL
    public let secretFileURL: URL

    public init(appGroupContainerURL: URL) {
        self.appGroupContainerURL = appGroupContainerURL
        self.secretFileURL = appGroupContainerURL.appendingPathComponent(
            FileAutoFillCredentialSecretStore.secretFileName,
            isDirectory: false
        )
    }

    public func save(_ snapshot: AutoFillCredentialSecretSnapshot) throws {
        try FileManager.default.createDirectory(
            at: appGroupContainerURL,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: secretFileURL, options: fileWritingOptions)
    }

    public func load() throws -> AutoFillCredentialSecretSnapshot? {
        guard FileManager.default.fileExists(atPath: secretFileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: secretFileURL)
        return try JSONDecoder().decode(AutoFillCredentialSecretSnapshot.self, from: data)
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: secretFileURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: secretFileURL)
    }

    private var fileWritingOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }
}

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
    private let session: LocalVaultSession
    private let engine: any LocalVaultEngine

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

    public func createLoginEntry(
        projectID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let normalizedDraft = try normalizedLoginEntryDraft(draft)
        return try engine.createLoginEntry(
            in: session.handle,
            projectID: projectID,
            draft: normalizedDraft
        )
    }

    public func listLoginEntries(projectID: String) throws -> [LocalLoginEntry] {
        try engine.listLoginEntries(
            in: session.handle,
            projectID: projectID
        )
    }

    public func updateLoginEntry(
        projectID: String,
        entryID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let normalizedDraft = try normalizedLoginEntryDraft(draft)
        return try engine.updateLoginEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            draft: normalizedDraft
        )
    }

    public func setLoginEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalLoginEntry {
        try engine.setLoginEntryFavorite(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
    }

    public func deleteLoginEntry(projectID: String, entryID: String) throws {
        try engine.deleteLoginEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func listDeletedLoginEntries(projectID: String) throws -> [LocalLoginEntry] {
        try engine.listDeletedLoginEntries(
            in: session.handle,
            projectID: projectID
        )
    }

    public func restoreLoginEntry(
        projectID: String,
        entryID: String
    ) throws -> LocalLoginEntry {
        try engine.restoreLoginEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func createNoteEntry(
        projectID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let normalizedDraft = try normalizedNoteEntryDraft(draft)
        return try engine.createNoteEntry(
            in: session.handle,
            projectID: projectID,
            draft: normalizedDraft
        )
    }

    public func listNoteEntries(projectID: String) throws -> [LocalNoteEntry] {
        try engine.listNoteEntries(in: session.handle, projectID: projectID)
    }

    public func updateNoteEntry(
        projectID: String,
        entryID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let normalizedDraft = try normalizedNoteEntryDraft(draft)
        return try engine.updateNoteEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            draft: normalizedDraft
        )
    }

    public func setNoteEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalNoteEntry {
        try engine.setNoteEntryFavorite(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
    }

    public func deleteNoteEntry(projectID: String, entryID: String) throws {
        try engine.deleteNoteEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func listDeletedNoteEntries(projectID: String) throws -> [LocalNoteEntry] {
        try engine.listDeletedNoteEntries(in: session.handle, projectID: projectID)
    }

    public func restoreNoteEntry(
        projectID: String,
        entryID: String
    ) throws -> LocalNoteEntry {
        try engine.restoreNoteEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func createTotpEntry(
        projectID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let normalizedDraft = try normalizedTotpEntryDraft(draft)
        return try engine.createTotpEntry(
            in: session.handle,
            projectID: projectID,
            draft: normalizedDraft
        )
    }

    public func listTotpEntries(projectID: String) throws -> [LocalTotpEntry] {
        try engine.listTotpEntries(in: session.handle, projectID: projectID)
    }

    public func updateTotpEntry(
        projectID: String,
        entryID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let normalizedDraft = try normalizedTotpEntryDraft(draft)
        return try engine.updateTotpEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            draft: normalizedDraft
        )
    }

    public func setTotpEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalTotpEntry {
        try engine.setTotpEntryFavorite(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
    }

    public func deleteTotpEntry(projectID: String, entryID: String) throws {
        try engine.deleteTotpEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func listDeletedTotpEntries(projectID: String) throws -> [LocalTotpEntry] {
        try engine.listDeletedTotpEntries(in: session.handle, projectID: projectID)
    }

    public func restoreTotpEntry(
        projectID: String,
        entryID: String
    ) throws -> LocalTotpEntry {
        try engine.restoreTotpEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func createCardEntry(
        projectID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let normalizedDraft = try normalizedCardEntryDraft(draft)
        return try engine.createCardEntry(
            in: session.handle,
            projectID: projectID,
            draft: normalizedDraft
        )
    }

    public func listCardEntries(projectID: String) throws -> [LocalCardEntry] {
        try engine.listCardEntries(in: session.handle, projectID: projectID)
    }

    public func updateCardEntry(
        projectID: String,
        entryID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let normalizedDraft = try normalizedCardEntryDraft(draft)
        return try engine.updateCardEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            draft: normalizedDraft
        )
    }

    public func setCardEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalCardEntry {
        try engine.setCardEntryFavorite(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
    }

    public func deleteCardEntry(projectID: String, entryID: String) throws {
        try engine.deleteCardEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func listDeletedCardEntries(projectID: String) throws -> [LocalCardEntry] {
        try engine.listDeletedCardEntries(in: session.handle, projectID: projectID)
    }

    public func restoreCardEntry(
        projectID: String,
        entryID: String
    ) throws -> LocalCardEntry {
        try engine.restoreCardEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func createIdentityEntry(
        projectID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let normalizedDraft = try normalizedIdentityEntryDraft(draft)
        return try engine.createIdentityEntry(
            in: session.handle,
            projectID: projectID,
            draft: normalizedDraft
        )
    }

    public func listIdentityEntries(projectID: String) throws -> [LocalIdentityEntry] {
        try engine.listIdentityEntries(in: session.handle, projectID: projectID)
    }

    public func updateIdentityEntry(
        projectID: String,
        entryID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let normalizedDraft = try normalizedIdentityEntryDraft(draft)
        return try engine.updateIdentityEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            draft: normalizedDraft
        )
    }

    public func setIdentityEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalIdentityEntry {
        try engine.setIdentityEntryFavorite(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
    }

    public func deleteIdentityEntry(projectID: String, entryID: String) throws {
        try engine.deleteIdentityEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func listDeletedIdentityEntries(projectID: String) throws -> [LocalIdentityEntry] {
        try engine.listDeletedIdentityEntries(in: session.handle, projectID: projectID)
    }

    public func restoreIdentityEntry(
        projectID: String,
        entryID: String
    ) throws -> LocalIdentityEntry {
        try engine.restoreIdentityEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func createPasskeyEntry(projectID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry {
        try engine.createPasskeyEntry(in: session.handle, projectID: projectID, draft: normalizedPasskeyEntryDraft(draft))
    }

    public func listPasskeyEntries(projectID: String) throws -> [LocalPasskeyEntry] {
        try engine.listPasskeyEntries(in: session.handle, projectID: projectID)
    }

    public func updatePasskeyEntry(projectID: String, entryID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry {
        try engine.updatePasskeyEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedPasskeyEntryDraft(draft))
    }

    public func setPasskeyEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalPasskeyEntry {
        try engine.setPasskeyEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deletePasskeyEntry(projectID: String, entryID: String) throws {
        try engine.deletePasskeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedPasskeyEntries(projectID: String) throws -> [LocalPasskeyEntry] {
        try engine.listDeletedPasskeyEntries(in: session.handle, projectID: projectID)
    }

    public func restorePasskeyEntry(projectID: String, entryID: String) throws -> LocalPasskeyEntry {
        try engine.restorePasskeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func createSshKeyEntry(projectID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        try engine.createSshKeyEntry(in: session.handle, projectID: projectID, draft: normalizedSshKeyEntryDraft(draft))
    }

    public func listSshKeyEntries(projectID: String) throws -> [LocalSshKeyEntry] {
        try engine.listSshKeyEntries(in: session.handle, projectID: projectID)
    }

    public func updateSshKeyEntry(projectID: String, entryID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        try engine.updateSshKeyEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedSshKeyEntryDraft(draft))
    }

    public func setSshKeyEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalSshKeyEntry {
        try engine.setSshKeyEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteSshKeyEntry(projectID: String, entryID: String) throws {
        try engine.deleteSshKeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedSshKeyEntries(projectID: String) throws -> [LocalSshKeyEntry] {
        try engine.listDeletedSshKeyEntries(in: session.handle, projectID: projectID)
    }

    public func restoreSshKeyEntry(projectID: String, entryID: String) throws -> LocalSshKeyEntry {
        try engine.restoreSshKeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func createApiTokenEntry(projectID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        try engine.createApiTokenEntry(in: session.handle, projectID: projectID, draft: normalizedApiTokenEntryDraft(draft))
    }

    public func listApiTokenEntries(projectID: String) throws -> [LocalApiTokenEntry] {
        try engine.listApiTokenEntries(in: session.handle, projectID: projectID)
    }

    public func updateApiTokenEntry(projectID: String, entryID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        try engine.updateApiTokenEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedApiTokenEntryDraft(draft))
    }

    public func setApiTokenEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalApiTokenEntry {
        try engine.setApiTokenEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteApiTokenEntry(projectID: String, entryID: String) throws {
        try engine.deleteApiTokenEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedApiTokenEntries(projectID: String) throws -> [LocalApiTokenEntry] {
        try engine.listDeletedApiTokenEntries(in: session.handle, projectID: projectID)
    }

    public func restoreApiTokenEntry(projectID: String, entryID: String) throws -> LocalApiTokenEntry {
        try engine.restoreApiTokenEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func createWifiEntry(projectID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        try engine.createWifiEntry(in: session.handle, projectID: projectID, draft: normalizedWifiEntryDraft(draft))
    }

    public func listWifiEntries(projectID: String) throws -> [LocalWifiEntry] {
        try engine.listWifiEntries(in: session.handle, projectID: projectID)
    }

    public func updateWifiEntry(projectID: String, entryID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        try engine.updateWifiEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedWifiEntryDraft(draft))
    }

    public func setWifiEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalWifiEntry {
        try engine.setWifiEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteWifiEntry(projectID: String, entryID: String) throws {
        try engine.deleteWifiEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedWifiEntries(projectID: String) throws -> [LocalWifiEntry] {
        try engine.listDeletedWifiEntries(in: session.handle, projectID: projectID)
    }

    public func restoreWifiEntry(projectID: String, entryID: String) throws -> LocalWifiEntry {
        try engine.restoreWifiEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func createSendEntry(projectID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry {
        try engine.createSendEntry(in: session.handle, projectID: projectID, draft: normalizedSendEntryDraft(draft))
    }

    public func listSendEntries(projectID: String) throws -> [LocalSendEntry] {
        try engine.listSendEntries(in: session.handle, projectID: projectID)
    }

    public func updateSendEntry(projectID: String, entryID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry {
        try engine.updateSendEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedSendEntryDraft(draft))
    }

    public func setSendEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalSendEntry {
        try engine.setSendEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteSendEntry(projectID: String, entryID: String) throws {
        try engine.deleteSendEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedSendEntries(projectID: String) throws -> [LocalSendEntry] {
        try engine.listDeletedSendEntries(in: session.handle, projectID: projectID)
    }

    public func restoreSendEntry(projectID: String, entryID: String) throws -> LocalSendEntry {
        try engine.restoreSendEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func createAttachmentMetadata(
        projectID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String
    ) throws -> LocalAttachmentMetadata {
        let normalizedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFileName.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return try engine.createAttachmentMetadata(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            fileName: normalizedFileName,
            mediaType: mediaType,
            originalSize: originalSize,
            storedSize: storedSize,
            contentHash: contentHash,
            storageMode: storageMode
        )
    }

    public func listAttachmentMetadata(projectID: String) throws -> [LocalAttachmentMetadata] {
        try engine.listAttachmentMetadata(in: session.handle, projectID: projectID)
    }

    public func deleteAttachmentMetadata(projectID: String, attachmentID: String) throws {
        try engine.deleteAttachmentMetadata(in: session.handle, projectID: projectID, attachmentID: attachmentID)
    }

    public func listDeletedAttachmentMetadata(projectID: String) throws -> [LocalAttachmentMetadata] {
        try engine.listDeletedAttachmentMetadata(in: session.handle, projectID: projectID)
    }

    public func restoreAttachmentMetadata(projectID: String, attachmentID: String) throws -> LocalAttachmentMetadata {
        try engine.restoreAttachmentMetadata(in: session.handle, projectID: projectID, attachmentID: attachmentID)
    }

    private func normalizedProjectTitle(_ title: String) throws -> String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LocalVaultRepositoryError.emptyProjectTitle
        }
        return normalized
    }

    private func normalizedLoginEntryDraft(_ draft: LocalLoginEntryDraft) throws -> LocalLoginEntryDraft {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return LocalLoginEntryDraft(
            title: normalizedTitle,
            username: draft.username,
            password: draft.password,
            url: draft.url
        )
    }

    private func normalizedNoteEntryDraft(_ draft: LocalNoteEntryDraft) throws -> LocalNoteEntryDraft {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return LocalNoteEntryDraft(title: normalizedTitle, body: draft.body)
    }

    private func normalizedTotpEntryDraft(_ draft: LocalTotpEntryDraft) throws -> LocalTotpEntryDraft {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return LocalTotpEntryDraft(
            title: normalizedTitle,
            secret: draft.secret,
            issuer: draft.issuer,
            accountName: draft.accountName,
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm,
            otpType: draft.otpType,
            counter: draft.counter
        )
    }

    private func normalizedCardEntryDraft(_ draft: LocalCardEntryDraft) throws -> LocalCardEntryDraft {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return LocalCardEntryDraft(
            title: normalizedTitle,
            cardholderName: draft.cardholderName,
            number: draft.number,
            expiryMonth: draft.expiryMonth,
            expiryYear: draft.expiryYear,
            cvv: draft.cvv,
            issuer: draft.issuer,
            network: draft.network,
            notes: draft.notes
        )
    }

    private func normalizedIdentityEntryDraft(_ draft: LocalIdentityEntryDraft) throws -> LocalIdentityEntryDraft {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return LocalIdentityEntryDraft(
            title: normalizedTitle,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes
        )
    }

    private func normalizedPasskeyEntryDraft(_ draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalPasskeyEntryDraft(
            title: normalizedTitle,
            relyingPartyID: draft.relyingPartyID,
            username: draft.username,
            userHandle: draft.userHandle,
            credentialID: draft.credentialID,
            publicKeyCOSE: draft.publicKeyCOSE,
            privateKeyReference: draft.privateKeyReference,
            notes: draft.notes
        )
    }

    private func normalizedSshKeyEntryDraft(_ draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalSshKeyEntryDraft(
            title: normalizedTitle,
            username: draft.username,
            host: draft.host,
            publicKey: draft.publicKey,
            privateKeyReference: draft.privateKeyReference,
            passphraseHint: draft.passphraseHint,
            notes: draft.notes
        )
    }

    private func normalizedApiTokenEntryDraft(_ draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalApiTokenEntryDraft(
            title: normalizedTitle,
            issuer: draft.issuer,
            accountName: draft.accountName,
            token: draft.token,
            scopes: draft.scopes,
            expiresAt: draft.expiresAt,
            notes: draft.notes
        )
    }

    private func normalizedWifiEntryDraft(_ draft: LocalWifiEntryDraft) throws -> LocalWifiEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalWifiEntryDraft(
            title: normalizedTitle,
            ssid: draft.ssid,
            securityType: draft.securityType,
            password: draft.password,
            hidden: draft.hidden,
            notes: draft.notes
        )
    }

    private func normalizedSendEntryDraft(_ draft: LocalSendEntryDraft) throws -> LocalSendEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalSendEntryDraft(
            title: normalizedTitle,
            body: draft.body,
            expiresAt: draft.expiresAt,
            maxViews: draft.maxViews,
            notes: draft.notes
        )
    }

    private func normalizedEntryTitle(_ title: String) throws -> String {
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
    }

    public func createProject(
        in handle: LocalVaultHandle,
        title: String
    ) throws -> LocalVaultProject {
        let project = try vault(for: handle).createProject(title: title)
        return LocalVaultProject(id: project.id, title: project.title)
    }

    public func createLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let entry = try vault(for: handle).createLoginEntry(
            projectID: projectID,
            title: draft.title,
            username: draft.username,
            password: draft.password,
            url: draft.url
        )
        return LocalLoginEntry(entry)
    }

    public func listLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry] {
        try vault(for: handle)
            .listLoginEntries(projectID: projectID)
            .map(LocalLoginEntry.init)
    }

    public func updateLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let entry = try vault(for: handle).updateLoginEntry(
            projectID: projectID,
            entryID: entryID,
            title: draft.title,
            username: draft.username,
            password: draft.password,
            url: draft.url
        )
        return LocalLoginEntry(entry)
    }

    public func deleteLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        try vault(for: handle).deleteLoginEntry(projectID: projectID, entryID: entryID)
    }

    public func setLoginEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalLoginEntry {
        let entry = try vault(for: handle).setLoginEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
        return LocalLoginEntry(entry)
    }

    public func listDeletedLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry] {
        try vault(for: handle)
            .listDeletedLoginEntries(projectID: projectID)
            .map(LocalLoginEntry.init)
    }

    public func restoreLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalLoginEntry {
        let entry = try vault(for: handle).restoreLoginEntry(
            projectID: projectID,
            entryID: entryID
        )
        return LocalLoginEntry(entry)
    }

    public func createNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let entry = try vault(for: handle).createNoteEntry(
            projectID: projectID,
            title: draft.title,
            body: draft.body
        )
        return LocalNoteEntry(entry)
    }

    public func listNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry] {
        try vault(for: handle)
            .listNoteEntries(projectID: projectID)
            .map(LocalNoteEntry.init)
    }

    public func updateNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let entry = try vault(for: handle).updateNoteEntry(
            projectID: projectID,
            entryID: entryID,
            title: draft.title,
            body: draft.body
        )
        return LocalNoteEntry(entry)
    }

    public func setNoteEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalNoteEntry {
        let entry = try vault(for: handle).setNoteEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
        return LocalNoteEntry(entry)
    }

    public func deleteNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        try vault(for: handle).deleteNoteEntry(projectID: projectID, entryID: entryID)
    }

    public func listDeletedNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry] {
        try vault(for: handle)
            .listDeletedNoteEntries(projectID: projectID)
            .map(LocalNoteEntry.init)
    }

    public func restoreNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalNoteEntry {
        let entry = try vault(for: handle).restoreNoteEntry(
            projectID: projectID,
            entryID: entryID
        )
        return LocalNoteEntry(entry)
    }

    public func createTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let entry = try vault(for: handle).createTotpEntry(
            projectID: projectID,
            title: draft.title,
            secret: draft.secret,
            issuer: draft.issuer,
            accountName: draft.accountName,
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm,
            otpType: draft.otpType,
            counter: draft.counter
        )
        return LocalTotpEntry(entry)
    }

    public func listTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry] {
        try vault(for: handle)
            .listTotpEntries(projectID: projectID)
            .map(LocalTotpEntry.init)
    }

    public func updateTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let entry = try vault(for: handle).updateTotpEntry(
            projectID: projectID,
            entryID: entryID,
            title: draft.title,
            secret: draft.secret,
            issuer: draft.issuer,
            accountName: draft.accountName,
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm,
            otpType: draft.otpType,
            counter: draft.counter
        )
        return LocalTotpEntry(entry)
    }

    public func setTotpEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalTotpEntry {
        let entry = try vault(for: handle).setTotpEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
        return LocalTotpEntry(entry)
    }

    public func deleteTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        try vault(for: handle).deleteTotpEntry(projectID: projectID, entryID: entryID)
    }

    public func listDeletedTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry] {
        try vault(for: handle)
            .listDeletedTotpEntries(projectID: projectID)
            .map(LocalTotpEntry.init)
    }

    public func restoreTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalTotpEntry {
        let entry = try vault(for: handle).restoreTotpEntry(
            projectID: projectID,
            entryID: entryID
        )
        return LocalTotpEntry(entry)
    }

    public func createCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let entry = try vault(for: handle).createCardEntry(
            projectID: projectID,
            title: draft.title,
            cardholderName: draft.cardholderName,
            number: draft.number,
            expiryMonth: draft.expiryMonth,
            expiryYear: draft.expiryYear,
            cvv: draft.cvv,
            issuer: draft.issuer,
            network: draft.network,
            notes: draft.notes
        )
        return LocalCardEntry(entry)
    }

    public func listCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry] {
        try vault(for: handle)
            .listCardEntries(projectID: projectID)
            .map(LocalCardEntry.init)
    }

    public func updateCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let entry = try vault(for: handle).updateCardEntry(
            projectID: projectID,
            entryID: entryID,
            title: draft.title,
            cardholderName: draft.cardholderName,
            number: draft.number,
            expiryMonth: draft.expiryMonth,
            expiryYear: draft.expiryYear,
            cvv: draft.cvv,
            issuer: draft.issuer,
            network: draft.network,
            notes: draft.notes
        )
        return LocalCardEntry(entry)
    }

    public func setCardEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalCardEntry {
        let entry = try vault(for: handle).setCardEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
        return LocalCardEntry(entry)
    }

    public func deleteCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        try vault(for: handle).deleteCardEntry(projectID: projectID, entryID: entryID)
    }

    public func listDeletedCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry] {
        try vault(for: handle)
            .listDeletedCardEntries(projectID: projectID)
            .map(LocalCardEntry.init)
    }

    public func restoreCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalCardEntry {
        let entry = try vault(for: handle).restoreCardEntry(
            projectID: projectID,
            entryID: entryID
        )
        return LocalCardEntry(entry)
    }

    public func createIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let entry = try vault(for: handle).createIdentityEntry(
            projectID: projectID,
            title: draft.title,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes
        )
        return LocalIdentityEntry(entry)
    }

    public func listIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry] {
        try vault(for: handle)
            .listIdentityEntries(projectID: projectID)
            .map(LocalIdentityEntry.init)
    }

    public func updateIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let entry = try vault(for: handle).updateIdentityEntry(
            projectID: projectID,
            entryID: entryID,
            title: draft.title,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes
        )
        return LocalIdentityEntry(entry)
    }

    public func setIdentityEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalIdentityEntry {
        let entry = try vault(for: handle).setIdentityEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
        return LocalIdentityEntry(entry)
    }

    public func deleteIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        try vault(for: handle).deleteIdentityEntry(projectID: projectID, entryID: entryID)
    }

    public func listDeletedIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry] {
        try vault(for: handle)
            .listDeletedIdentityEntries(projectID: projectID)
            .map(LocalIdentityEntry.init)
    }

    public func restoreIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalIdentityEntry {
        let entry = try vault(for: handle).restoreIdentityEntry(
            projectID: projectID,
            entryID: entryID
        )
        return LocalIdentityEntry(entry)
    }

    public func createPasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalPasskeyEntryDraft
    ) throws -> LocalPasskeyEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "passkey",
            kind: "passkey",
            title: draft.title,
            payload: [
                "relyingPartyID": draft.relyingPartyID,
                "username": draft.username,
                "userHandle": draft.userHandle,
                "credentialID": draft.credentialID,
                "publicKeyCOSE": draft.publicKeyCOSE,
                "privateKeyReference": draft.privateKeyReference,
                "notes": draft.notes
            ]
        )
        return try LocalPasskeyEntry(entry)
    }

    public func listPasskeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPasskeyEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "passkey", kind: "passkey").map(LocalPasskeyEntry.init)
    }

    public func updatePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "passkey",
            kind: "passkey",
            title: draft.title,
            payload: [
                "relyingPartyID": draft.relyingPartyID,
                "username": draft.username,
                "userHandle": draft.userHandle,
                "credentialID": draft.credentialID,
                "publicKeyCOSE": draft.publicKeyCOSE,
                "privateKeyReference": draft.privateKeyReference,
                "notes": draft.notes
            ]
        )
        return try LocalPasskeyEntry(entry)
    }

    public func setPasskeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalPasskeyEntry {
        try LocalPasskeyEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "passkey", kind: "passkey", favorite: favorite))
    }

    public func deletePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "passkey", kind: "passkey")
    }

    public func listDeletedPasskeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPasskeyEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "passkey", kind: "passkey").map(LocalPasskeyEntry.init)
    }

    public func restorePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalPasskeyEntry {
        try LocalPasskeyEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "passkey", kind: "passkey"))
    }

    public func createSshKeyEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "ssh-key",
            kind: "ssh-key",
            title: draft.title,
            payload: [
                "username": draft.username,
                "host": draft.host,
                "publicKey": draft.publicKey,
                "privateKeyReference": draft.privateKeyReference,
                "passphraseHint": draft.passphraseHint,
                "notes": draft.notes
            ]
        )
        return try LocalSshKeyEntry(entry)
    }

    public func listSshKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSshKeyEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "ssh-key", kind: "ssh-key").map(LocalSshKeyEntry.init)
    }

    public func updateSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "ssh-key",
            kind: "ssh-key",
            title: draft.title,
            payload: [
                "username": draft.username,
                "host": draft.host,
                "publicKey": draft.publicKey,
                "privateKeyReference": draft.privateKeyReference,
                "passphraseHint": draft.passphraseHint,
                "notes": draft.notes
            ]
        )
        return try LocalSshKeyEntry(entry)
    }

    public func setSshKeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSshKeyEntry {
        try LocalSshKeyEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "ssh-key", kind: "ssh-key", favorite: favorite))
    }

    public func deleteSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "ssh-key", kind: "ssh-key")
    }

    public func listDeletedSshKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSshKeyEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "ssh-key", kind: "ssh-key").map(LocalSshKeyEntry.init)
    }

    public func restoreSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSshKeyEntry {
        try LocalSshKeyEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "ssh-key", kind: "ssh-key"))
    }

    public func createApiTokenEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "api-token",
            kind: "api-token",
            title: draft.title,
            payload: [
                "issuer": draft.issuer,
                "accountName": draft.accountName,
                "token": draft.token,
                "scopes": draft.scopes,
                "expiresAt": draft.expiresAt,
                "notes": draft.notes
            ]
        )
        return try LocalApiTokenEntry(entry)
    }

    public func listApiTokenEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalApiTokenEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "api-token", kind: "api-token").map(LocalApiTokenEntry.init)
    }

    public func updateApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "api-token",
            kind: "api-token",
            title: draft.title,
            payload: [
                "issuer": draft.issuer,
                "accountName": draft.accountName,
                "token": draft.token,
                "scopes": draft.scopes,
                "expiresAt": draft.expiresAt,
                "notes": draft.notes
            ]
        )
        return try LocalApiTokenEntry(entry)
    }

    public func setApiTokenEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalApiTokenEntry {
        try LocalApiTokenEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "api-token", kind: "api-token", favorite: favorite))
    }

    public func deleteApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "api-token", kind: "api-token")
    }

    public func listDeletedApiTokenEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalApiTokenEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "api-token", kind: "api-token").map(LocalApiTokenEntry.init)
    }

    public func restoreApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalApiTokenEntry {
        try LocalApiTokenEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "api-token", kind: "api-token"))
    }

    public func createWifiEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "wifi",
            title: draft.title,
            payload: [
                "ssid": draft.ssid,
                "securityType": draft.securityType,
                "password": draft.password,
                "hidden": draft.hidden,
                "notes": draft.notes
            ]
        )
        return try LocalWifiEntry(entry)
    }

    public func listWifiEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalWifiEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "wifi").map(LocalWifiEntry.init)
    }

    public func updateWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "wifi",
            title: draft.title,
            payload: [
                "ssid": draft.ssid,
                "securityType": draft.securityType,
                "password": draft.password,
                "hidden": draft.hidden,
                "notes": draft.notes
            ]
        )
        return try LocalWifiEntry(entry)
    }

    public func setWifiEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalWifiEntry {
        try LocalWifiEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "wifi", favorite: favorite))
    }

    public func deleteWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "wifi")
    }

    public func listDeletedWifiEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalWifiEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "wifi").map(LocalWifiEntry.init)
    }

    public func restoreWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalWifiEntry {
        try LocalWifiEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "wifi"))
    }

    public func createSendEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "send",
            title: draft.title,
            payload: [
                "body": draft.body,
                "expiresAt": draft.expiresAt,
                "maxViews": draft.maxViews,
                "notes": draft.notes
            ]
        )
        return try LocalSendEntry(entry)
    }

    public func listSendEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSendEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "send").map(LocalSendEntry.init)
    }

    public func updateSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "send",
            title: draft.title,
            payload: [
                "body": draft.body,
                "expiresAt": draft.expiresAt,
                "maxViews": draft.maxViews,
                "notes": draft.notes
            ]
        )
        return try LocalSendEntry(entry)
    }

    public func setSendEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSendEntry {
        try LocalSendEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "send", favorite: favorite))
    }

    public func deleteSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "send")
    }

    public func listDeletedSendEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSendEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "send").map(LocalSendEntry.init)
    }

    public func restoreSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSendEntry {
        try LocalSendEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "send"))
    }

    public func createAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String
    ) throws -> LocalAttachmentMetadata {
        var payload: [String: Any] = [
            "fileName": fileName,
            "mediaType": mediaType,
            "originalSize": originalSize,
            "storedSize": storedSize,
            "contentHash": contentHash,
            "storageMode": storageMode
        ]
        if let entryID {
            payload["entryID"] = entryID
        }
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "attachment-ref",
            title: fileName,
            payload: payload
        )
        return try LocalAttachmentMetadata(entry, deleted: false)
    }

    public func listAttachmentMetadata(in handle: LocalVaultHandle, projectID: String) throws -> [LocalAttachmentMetadata] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "attachment-ref")
            .map { try LocalAttachmentMetadata($0, deleted: false) }
    }

    public func deleteAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String) throws {
        try deleteParityEntry(
            in: handle,
            projectID: projectID,
            entryID: attachmentID,
            entryType: "document-ref",
            kind: "attachment-ref"
        )
    }

    public func listDeletedAttachmentMetadata(in handle: LocalVaultHandle, projectID: String) throws -> [LocalAttachmentMetadata] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "attachment-ref")
            .map { try LocalAttachmentMetadata($0, deleted: true) }
    }

    public func restoreAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String) throws -> LocalAttachmentMetadata {
        let entry = try restoreParityEntry(
            in: handle,
            projectID: projectID,
            entryID: attachmentID,
            entryType: "document-ref",
            kind: "attachment-ref"
        )
        return try LocalAttachmentMetadata(entry, deleted: false)
    }

    private func store(_ vault: MonicaMDBXVault, vaultID: String) {
        lock.lock()
        defer { lock.unlock() }
        vaults[vaultID] = vault
    }

    private func vault(for handle: LocalVaultHandle) throws -> MonicaMDBXVault {
        lock.lock()
        defer { lock.unlock() }
        guard let vault = vaults[handle.vaultID] else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        return vault
    }

    private func createParityEntry(
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

    private func listParityEntries(
        in handle: LocalVaultHandle,
        projectID: String,
        entryType: String,
        kind: String
    ) throws -> [MonicaMDBXParityEntry] {
        try vault(for: handle).listParityEntries(projectID: projectID, entryType: entryType, kind: kind)
    }

    private func listDeletedParityEntries(
        in handle: LocalVaultHandle,
        projectID: String,
        entryType: String,
        kind: String
    ) throws -> [MonicaMDBXParityEntry] {
        try vault(for: handle).listDeletedParityEntries(projectID: projectID, entryType: entryType, kind: kind)
    }

    private func updateParityEntry(
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

    private func setParityEntryFavorite(
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

    private func deleteParityEntry(
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

    private func restoreParityEntry(
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

    private func parityPayloadJSON(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        return json
    }
}

private extension LocalLoginEntry {
    init(_ entry: MonicaMDBXLoginEntry) {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            username: entry.username,
            password: entry.password,
            url: entry.url,
            favorite: entry.favorite
        )
    }
}

private extension LocalNoteEntry {
    init(_ entry: MonicaMDBXNoteEntry) {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            body: entry.body,
            favorite: entry.favorite
        )
    }
}

private extension LocalTotpEntry {
    init(_ entry: MonicaMDBXTotpEntry) {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            secret: entry.secret,
            issuer: entry.issuer,
            accountName: entry.accountName,
            period: entry.period,
            digits: entry.digits,
            algorithm: entry.algorithm,
            otpType: entry.otpType,
            counter: entry.counter,
            favorite: entry.favorite
        )
    }
}

private extension LocalCardEntry {
    init(_ entry: MonicaMDBXCardEntry) {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            cardholderName: entry.cardholderName,
            number: entry.number,
            expiryMonth: entry.expiryMonth,
            expiryYear: entry.expiryYear,
            cvv: entry.cvv,
            issuer: entry.issuer,
            network: entry.network,
            notes: entry.notes,
            favorite: entry.favorite
        )
    }
}

private extension LocalIdentityEntry {
    init(_ entry: MonicaMDBXIdentityEntry) {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            documentType: entry.documentType,
            fullName: entry.fullName,
            documentNumber: entry.documentNumber,
            issuer: entry.issuer,
            country: entry.country,
            issueDate: entry.issueDate,
            expiryDate: entry.expiryDate,
            notes: entry.notes,
            favorite: entry.favorite
        )
    }
}

private extension LocalPasskeyEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            relyingPartyID: payload.string("relyingPartyID"),
            username: payload.string("username"),
            userHandle: payload.string("userHandle"),
            credentialID: payload.string("credentialID"),
            publicKeyCOSE: payload.string("publicKeyCOSE"),
            privateKeyReference: payload.string("privateKeyReference"),
            notes: payload.string("notes"),
            favorite: entry.favorite
        )
    }
}

private extension LocalSshKeyEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            username: payload.string("username"),
            host: payload.string("host"),
            publicKey: payload.string("publicKey"),
            privateKeyReference: payload.string("privateKeyReference"),
            passphraseHint: payload.string("passphraseHint"),
            notes: payload.string("notes"),
            favorite: entry.favorite
        )
    }
}

private extension LocalApiTokenEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            issuer: payload.string("issuer"),
            accountName: payload.string("accountName"),
            token: payload.string("token"),
            scopes: payload.string("scopes"),
            expiresAt: payload.string("expiresAt"),
            notes: payload.string("notes"),
            favorite: entry.favorite
        )
    }
}

private extension LocalWifiEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            ssid: payload.string("ssid"),
            securityType: payload.string("securityType"),
            password: payload.string("password"),
            hidden: payload.bool("hidden"),
            notes: payload.string("notes"),
            favorite: entry.favorite
        )
    }
}

private extension LocalSendEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            body: payload.string("body"),
            expiresAt: payload.string("expiresAt"),
            maxViews: payload.int("maxViews"),
            notes: payload.string("notes"),
            favorite: entry.favorite
        )
    }
}

private extension LocalAttachmentMetadata {
    init(_ entry: MonicaMDBXParityEntry, deleted: Bool) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            entryID: payload.optionalString("entryID"),
            fileName: payload.string("fileName"),
            mediaType: payload.string("mediaType"),
            originalSize: payload.int64("originalSize"),
            storedSize: payload.int64("storedSize"),
            contentHash: payload.string("contentHash"),
            storageMode: payload.string("storageMode"),
            deleted: deleted
        )
    }
}

private extension MonicaMDBXParityEntry {
    func payloadDictionary() throws -> [String: Any] {
        guard let data = payloadJSON.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        return payload
    }
}

private extension Dictionary where Key == String, Value == Any {
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
