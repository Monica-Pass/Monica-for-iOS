// MARK: - CSV 导入导出（VaultCSVItemDraft / VaultCSVCodec）

import Foundation

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
    case sso(LocalSSOEntryDraft)
    case send(LocalSendEntryDraft)
    case steam(LocalSteamEntryDraft)
    case barcode(LocalBarcodeEntryDraft)
    case billingAddress(LocalBillingAddressEntryDraft)
    case paymentAccount(LocalPaymentAccountEntryDraft)

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
        case .sso: return .sso
        case .send: return .send
        case .steam: return .steam
        case .barcode: return .barcode
        case .billingAddress: return .billingAddress
        case .paymentAccount: return .paymentAccount
        }
    }

    /// 备份导出时随条目一起写入的标签与归档状态。
    public var metadata: VaultEntryMetadata {
        switch self {
        case .login(let draft): return draft.metadata
        case .note(let draft): return draft.metadata
        case .totp(let draft): return draft.metadata
        case .card(let draft): return draft.metadata
        case .identity(let draft): return draft.metadata
        case .passkey(let draft): return draft.metadata
        case .sshKey(let draft): return draft.metadata
        case .apiToken(let draft): return draft.metadata
        case .wifi(let draft): return draft.metadata
        case .sso(let draft): return draft.metadata
        case .send(let draft): return draft.metadata
        case .steam(let draft): return draft.metadata
        case .barcode(let draft): return draft.metadata
        case .billingAddress(let draft): return draft.metadata
        case .paymentAccount(let draft): return draft.metadata
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
    case invalidFieldFormat
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
        "iban",
        "swiftCode",
        "billingAddress",
        "cardArtwork",
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
        "ssoProvider",
        "ssoProviderName",
        "linkedLoginEntryID",
        "streetAddress",
        "apartment",
        "city",
        "stateProvince",
        "postalCode",
        "phone",
        "linkedCardIDs",
        "paymentType",
        "provider",
        "accountHolderName",
        "swiftBic",
        "routingNumber",
        "accountNumber",
        "currency",
        "linkedCardID",
        "billingAddressID",
        "notes",
        // 追加列：旧 CSV 没有这些列时按空值回落，保证旧文件仍可导入。
        "urls",
        "customFields",
        "payload",
        "symbology",
        "label",
        // issue #151：登录账号（邮箱 / 手机号 / 账号 ID），追加在末尾，不打乱既有列顺序。
        "account"
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

    /// 带自定义字段的 CSV 导出：列顺序与 `columns` 一致，旧读取端会忽略多出来的列。
    public static func exportTransferItems(_ items: [VaultTransferItem]) -> String {
        let rows = [columns] + items.map { item -> [String] in
            var values = rowValues(for: item.draft)
            if !item.customFields.isEmpty {
                values["customFields"] = VaultCustomFieldPayload.encode(item.customFields)
            }
            return columns.map { values[$0] ?? "" }
        }
        return rows.map { row in row.map(escape).joined(separator: ",") }.joined(separator: "\n")
    }

    static func parseItem(
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
                // 旧 CSV 没有 account 列时按空字符串回落。
                account: record.value("account"),
                password: record.value("password"),
                url: record.value("url"),
                notes: record.value("notes"),
                urls: urlList(record.value("urls"))
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
        case .steam:
            return .steam(LocalSteamEntryDraft(
                title: title,
                accountName: record.value("accountName"),
                steamID: record.value("steamID"),
                sharedSecret: record.value("secret"),
                issuer: record.value("issuer", fallback: "Steam"),
                notes: record.value("notes")
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
                iban: record.value("iban"),
                swiftCode: record.value("swiftCode"),
                billingAddress: record.value("billingAddress"),
                cardArtwork: record.value("cardArtwork"),
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
                notes: record.value("notes"),
                algorithm: record.value("algorithm"),
                keySize: Int(record.value("keySize")) ?? 0,
                fingerprint: record.value("fingerprint")
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
        case .sso:
            let provider = SSOProvider.fromStoredValue(record.value("ssoProvider"))
            let linkedID = record.value("linkedLoginEntryID")
            let loginURL = record.value("url")
            if !loginURL.isEmpty, SSOEntryURLValidator.error(for: loginURL) != nil {
                issues.append(issue(row: rowNumber, code: .invalidNumber, field: "url", detail: "SSO 登录地址不是合法的 http/https 地址"))
                return nil
            }
            return .sso(LocalSSOEntryDraft(
                title: title,
                provider: provider,
                providerName: record.value("ssoProviderName"),
                issuer: record.value("issuer"),
                accountName: record.value("username"),
                loginURL: loginURL,
                linkedLoginEntryID: linkedID.isEmpty ? nil : linkedID,
                notes: record.value("notes"),
                secret: record.value("secret")
            ))
        case .barcode:
            let symbologyValue = record.value("symbology", fallback: BarcodeSymbology.qr.rawValue)
            guard let symbology = BarcodeSymbology(rawValue: symbologyValue) else {
                issues.append(issue(row: rowNumber, code: .unsupportedKind, field: "symbology", detail: "不支持的条码制式"))
                return nil
            }
            return .barcode(LocalBarcodeEntryDraft(
                title: title,
                symbology: symbology,
                payload: record.value("payload"),
                label: record.value("label"),
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
        case .billingAddress:
            let addressDraft = LocalBillingAddressEntryDraft(
                title: title,
                fullName: record.value("fullName"),
                streetAddress: record.value("streetAddress"),
                apartment: record.value("apartment"),
                city: record.value("city"),
                stateProvince: record.value("stateProvince"),
                postalCode: record.value("postalCode"),
                country: record.value("country"),
                phone: record.value("phone"),
                notes: record.value("notes"),
                linkedCardIDs: splitVaultReferenceIdentifiers(record.value("linkedCardIDs"))
            )
            if let field = formatIssueField(for: addressDraft) {
                issues.append(issue(row: rowNumber, code: .invalidFieldFormat, field: field, detail: "字段格式可能不正确（仅提示，不影响导入）"))
            }
            return .billingAddress(addressDraft)
        case .paymentAccount:
            let accountDraft = LocalPaymentAccountEntryDraft(
                title: title,
                kind: LocalPaymentAccountKind(androidName: record.value("paymentType")),
                provider: record.value("provider"),
                accountName: record.value("accountName"),
                accountHolderName: record.value("accountHolderName"),
                iban: record.value("iban"),
                swiftBIC: record.value("swiftBic"),
                routingNumber: record.value("routingNumber"),
                accountNumber: record.value("accountNumber"),
                currency: record.value("currency"),
                notes: record.value("notes"),
                linkedCardID: record.value("linkedCardID"),
                billingAddressID: record.value("billingAddressID")
            )
            if let field = formatIssueField(for: accountDraft) {
                issues.append(issue(row: rowNumber, code: .invalidFieldFormat, field: field, detail: "字段格式可能不正确（仅提示，不影响导入）"))
            }
            return .paymentAccount(accountDraft)
        case .attachmentRef:
            issues.append(issue(row: rowNumber, code: .unsupportedKind, field: "kind", detail: "CSV 未包含可导入的附件内容"))
            return nil
        case .gpgKey:
            // armored 公钥体量大、且私钥不应经过 CSV 明文通道，因此 GPG 条目暂不支持 CSV 导入导出。
            issues.append(issue(row: rowNumber, code: .unsupportedKind, field: "kind", detail: "GPG 密钥条目暂不支持 CSV 导入导出"))
            return nil
        }
    }

    static func rowValues(for item: VaultCSVItemDraft) -> [String: String] {
        var values = Dictionary(uniqueKeysWithValues: columns.map { ($0, "") })
        values["kind"] = item.kind.rawValue
        switch item {
        case .login(let draft):
            values["title"] = draft.title
            values["username"] = draft.username
            values["account"] = draft.account
            values["password"] = draft.password
            values["url"] = draft.url
            values["notes"] = draft.notes
            // 主 URL 永远在第一项；只有存在额外链接时才写 urls 列，保证单 URL 条目原样往返。
            let normalizedURLs = LoginEntryURLRules.normalizedURLs(primary: draft.url, additional: draft.urls)
            if normalizedURLs.count > 1 || (normalizedURLs.count == 1 && normalizedURLs[0] != draft.url) {
                values["urls"] = normalizedURLs.joined(separator: "\n")
            }
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
        case .steam(let draft):
            values["title"] = draft.title
            values["accountName"] = draft.accountName
            values["steamID"] = draft.steamID
            values["secret"] = SteamSharedSecretValidator.normalizedBase64(draft.sharedSecret)
            values["issuer"] = draft.issuer
            values["notes"] = draft.notes
        case .card(let draft):
            values["title"] = draft.title
            values["cardholderName"] = draft.cardholderName
            values["number"] = draft.number
            values["expiryMonth"] = draft.expiryMonth
            values["expiryYear"] = draft.expiryYear
            values["cvv"] = draft.cvv
            values["issuer"] = draft.issuer
            values["network"] = draft.network
            values["iban"] = draft.iban
            values["swiftCode"] = draft.swiftCode
            values["billingAddress"] = draft.billingAddress
            values["cardArtwork"] = draft.cardArtwork
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
            // 生成器写入的元数据只在存在时导出，手工条目保持原有空列。
            if !draft.algorithm.isEmpty { values["algorithm"] = draft.algorithm }
            if draft.keySize > 0 { values["keySize"] = String(draft.keySize) }
            if !draft.fingerprint.isEmpty { values["fingerprint"] = draft.fingerprint }
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
        case .sso(let draft):
            values["title"] = draft.title
            values["username"] = draft.accountName
            values["url"] = draft.loginURL
            values["issuer"] = draft.issuer
            values["secret"] = draft.secret
            values["ssoProvider"] = draft.provider.rawValue
            values["ssoProviderName"] = draft.providerName
            values["linkedLoginEntryID"] = draft.linkedLoginEntryID ?? ""
            values["notes"] = draft.notes
        case .barcode(let draft):
            values["title"] = draft.title
            values["payload"] = draft.payload
            values["symbology"] = draft.symbology.rawValue
            values["label"] = draft.label
            values["notes"] = draft.notes
        case .send(let draft):
            values["title"] = draft.title
            values["body"] = draft.body
            values["expiresAt"] = draft.expiresAt
            values["maxViews"] = String(draft.maxViews)
            values["notes"] = draft.notes
        case .billingAddress(let draft):
            values["title"] = draft.title
            values["fullName"] = draft.fullName
            values["streetAddress"] = draft.streetAddress
            values["apartment"] = draft.apartment
            values["city"] = draft.city
            values["stateProvince"] = draft.stateProvince
            values["postalCode"] = draft.postalCode
            values["country"] = draft.country
            values["phone"] = draft.phone
            values["linkedCardIDs"] = joinedVaultReferenceIdentifiers(draft.linkedCardIDs)
            values["notes"] = draft.notes
        case .paymentAccount(let draft):
            values["title"] = draft.title
            values["paymentType"] = draft.kind.androidName
            values["provider"] = draft.provider
            values["accountName"] = draft.accountName
            values["accountHolderName"] = draft.accountHolderName
            values["iban"] = draft.iban
            values["swiftBic"] = draft.swiftBIC
            values["routingNumber"] = draft.routingNumber
            values["accountNumber"] = draft.accountNumber
            values["currency"] = draft.currency
            values["linkedCardID"] = draft.linkedCardID
            values["billingAddressID"] = draft.billingAddressID
            values["notes"] = draft.notes
        }
        return values
    }

    private static func row(for item: VaultCSVItemDraft) -> [String] {
        let values = rowValues(for: item)
        return columns.map { values[$0] ?? "" }
    }

    private static func formatIssueField(for draft: LocalBillingAddressEntryDraft) -> String? {
        if BillingFieldValidator.postalCodeIssue(draft.postalCode) != nil {
            return "postalCode"
        }
        return nil
    }

    private static func formatIssueField(for draft: LocalPaymentAccountEntryDraft) -> String? {
        if BillingFieldValidator.ibanIssue(draft.iban) != nil {
            return "iban"
        }
        if BillingFieldValidator.swiftBICIssue(draft.swiftBIC) != nil {
            return "swiftBic"
        }
        if BillingFieldValidator.routingNumberIssue(draft.routingNumber) != nil {
            return "routingNumber"
        }
        if BillingFieldValidator.currencyIssue(draft.currency) != nil {
            return "currency"
        }
        return nil
    }

    static func parseRows(_ csv: String) throws -> [[String]] {
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

    /// 多 URL 单元格：换行分隔；同时兼容手写文件里用 `|` 分隔的情况。
    private static func urlList(_ value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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

struct CSVRecord {
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
