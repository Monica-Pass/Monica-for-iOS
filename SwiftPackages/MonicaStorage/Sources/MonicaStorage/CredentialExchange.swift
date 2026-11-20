import Foundation

/// 凭据交换（Apple Credential Exchange Format，CXF）平台无关模型与映射。
///
/// 这一层不依赖 AuthenticationServices，负责把 CXF 账户/条目转换为本地条目草稿、
/// 去重、以及把本地条目转换为可导出的账户。系统 API 的桥接放在 App target。
public enum CredentialExchangeFormat {
    /// 当前实现支持并声明的 CXF 版本。
    public static let supportedVersion = "1.0"
}

public struct CredentialExchangePassword: Sendable, Equatable {
    public let userName: String
    public let password: String

    public init(userName: String, password: String) {
        self.userName = userName
        self.password = password
    }
}

public struct CredentialExchangeTOTP: Sendable, Equatable {
    public let secret: String
    public let period: UInt32
    public let digits: UInt32
    public let accountName: String
    public let issuer: String
    public let algorithm: String

    public init(
        secret: String,
        period: UInt32 = 30,
        digits: UInt32 = 6,
        accountName: String = "",
        issuer: String = "",
        algorithm: String = "SHA1"
    ) {
        self.secret = secret
        self.period = period
        self.digits = digits
        self.accountName = accountName
        self.issuer = issuer
        self.algorithm = algorithm
    }
}

/// 单个条目内可安全映射的凭据；无法安全迁移的类型（例如 Passkey 私钥）只计数、不入库。
public enum CredentialExchangeCredential: Sendable, Equatable {
    case password(CredentialExchangePassword)
    case totp(CredentialExchangeTOTP)
    case unsupported(label: String)
}

public struct CredentialExchangeItem: Sendable, Equatable {
    public let title: String
    public let urls: [String]
    public let favorite: Bool
    public let credentials: [CredentialExchangeCredential]

    public init(
        title: String,
        urls: [String] = [],
        favorite: Bool = false,
        credentials: [CredentialExchangeCredential]
    ) {
        self.title = title
        self.urls = urls
        self.favorite = favorite
        self.credentials = credentials
    }
}

public struct CredentialExchangeAccount: Sendable, Equatable {
    public let userName: String
    public let email: String
    public let fullName: String?
    public let items: [CredentialExchangeItem]

    public init(
        userName: String,
        email: String = "",
        fullName: String? = nil,
        items: [CredentialExchangeItem]
    ) {
        self.userName = userName
        self.email = email
        self.fullName = fullName
        self.items = items
    }
}

public struct CredentialExchangeImportPlan: Sendable, Equatable {
    public let drafts: [VaultCSVItemDraft]
    public let sourceAccountCount: Int
    public let sourceItemCount: Int
    public let passwordCount: Int
    public let totpCount: Int
    public let skippedDuplicateCount: Int
    public let unsupportedCredentialCount: Int
    public let invalidCredentialCount: Int

    public init(
        drafts: [VaultCSVItemDraft],
        sourceAccountCount: Int,
        sourceItemCount: Int,
        passwordCount: Int,
        totpCount: Int,
        skippedDuplicateCount: Int,
        unsupportedCredentialCount: Int,
        invalidCredentialCount: Int
    ) {
        self.drafts = drafts
        self.sourceAccountCount = sourceAccountCount
        self.sourceItemCount = sourceItemCount
        self.passwordCount = passwordCount
        self.totpCount = totpCount
        self.skippedDuplicateCount = skippedDuplicateCount
        self.unsupportedCredentialCount = unsupportedCredentialCount
        self.invalidCredentialCount = invalidCredentialCount
    }

    public var isEmpty: Bool { drafts.isEmpty }
    public var importableCount: Int { drafts.count }
}

public struct CredentialExchangeExportPlan: Sendable, Equatable {
    public let account: CredentialExchangeAccount
    public let passwordCount: Int
    public let totpCount: Int
    public let skippedCount: Int

    public init(
        account: CredentialExchangeAccount,
        passwordCount: Int,
        totpCount: Int,
        skippedCount: Int
    ) {
        self.account = account
        self.passwordCount = passwordCount
        self.totpCount = totpCount
        self.skippedCount = skippedCount
    }

    public var isEmpty: Bool { passwordCount == 0 && totpCount == 0 }
}

public enum CredentialExchangeCodec {
    /// CXF 的 TOTP secret 是 Base32 文本；入库前统一去掉空白与连字符、转大写，并校验可解码。
    public enum Base32 {
        private static let values: [Character: UInt32] = {
            var map: [Character: UInt32] = [:]
            for (index, character) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".enumerated() {
                map[character] = UInt32(index)
            }
            return map
        }()

        /// 返回规范化后的 Base32 文本；非法输入返回 nil。
        public static func normalizedSecret(_ rawValue: String) -> String? {
            var text = rawValue
                .replacingOccurrences(of: "\u{20}", with: "")
                .replacingOccurrences(of: "\t", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "-", with: "")
                .uppercased()
            while text.hasSuffix("=") {
                text.removeLast()
            }
            guard !text.isEmpty else { return nil }
            let remainder = text.count % 8
            guard remainder != 1, remainder != 3, remainder != 6 else { return nil }

            var buffer: UInt32 = 0
            var bitCount = 0
            var byteCount = 0
            for character in text {
                guard let value = values[character] else { return nil }
                buffer = (buffer << 5) | value
                bitCount += 5
                if bitCount >= 8 {
                    bitCount -= 8
                    byteCount += 1
                    if bitCount == 0 {
                        buffer = 0
                    } else {
                        buffer &= (UInt32(1) << UInt32(bitCount)) - 1
                    }
                }
            }
            // 尾部剩余位必须为零，否则不是规范的 Base32 编码。
            guard buffer == 0 else { return nil }
            // RFC 4226 建议共享密钥至少 80 位；少于 10 字节的密钥无法作为可靠的 TOTP 来源。
            guard byteCount >= 10 else { return nil }
            return text
        }

        public static func isValidSecret(_ rawValue: String) -> Bool {
            normalizedSecret(rawValue) != nil
        }
    }

    public static func normalizedURLKey(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let components = URLComponents(string: trimmed),
           let host = components.host?.lowercased(),
           !host.isEmpty {
            var path = components.path.lowercased()
            if path == "/" {
                path = ""
            }
            return host + path
        }
        return trimmed.lowercased()
    }

    public static func importPlan(
        accounts: [CredentialExchangeAccount],
        existingLoginEntries: [LocalLoginEntry] = [],
        existingTOTPEntries: [LocalTotpEntry] = []
    ) -> CredentialExchangeImportPlan {
        var drafts: [VaultCSVItemDraft] = []
        var sourceItemCount = 0
        var passwordCount = 0
        var totpCount = 0
        var skippedDuplicateCount = 0
        var unsupportedCredentialCount = 0
        var invalidCredentialCount = 0
        var seenLogins = Set<LoginIdentity>()
        var seenTOTP = Set<TOTPIdentity>()

        for entry in existingLoginEntries {
            seenLogins.insert(LoginIdentity(
                urlKey: normalizedURLKey(entry.url),
                userName: entry.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                password: entry.password
            ))
        }
        for entry in existingTOTPEntries {
            guard let secret = Base32.normalizedSecret(entry.secret) else { continue }
            seenTOTP.insert(TOTPIdentity(
                secret: secret,
                accountName: entry.accountName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ))
        }

        for account in accounts {
            for item in account.items {
                sourceItemCount += 1
                let urls = item.urls
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                for credential in item.credentials {
                    switch credential {
                    case .password(let password):
                        let userName = password.userName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !userName.isEmpty || !password.password.isEmpty else {
                            invalidCredentialCount += 1
                            continue
                        }
                        let url = urls.first ?? ""
                        let identity = LoginIdentity(
                            urlKey: normalizedURLKey(url),
                            userName: userName.lowercased(),
                            password: password.password
                        )
                        guard seenLogins.insert(identity).inserted else {
                            skippedDuplicateCount += 1
                            continue
                        }
                        drafts.append(.login(LocalLoginEntryDraft(
                            title: resolvedTitle(item.title, urls: urls, fallback: userName),
                            username: userName,
                            password: password.password,
                            url: url,
                            notes: ""
                        )))
                        passwordCount += 1
                    case .totp(let totp):
                        guard let secret = Base32.normalizedSecret(totp.secret) else {
                            invalidCredentialCount += 1
                            continue
                        }
                        let accountName = totp.accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? account.userName.trimmingCharacters(in: .whitespacesAndNewlines)
                            : totp.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard seenTOTP.insert(TOTPIdentity(
                            secret: secret,
                            accountName: accountName.lowercased()
                        )).inserted else {
                            skippedDuplicateCount += 1
                            continue
                        }
                        let issuer = totp.issuer.trimmingCharacters(in: .whitespacesAndNewlines)
                        let title = resolvedTitle(
                            item.title,
                            urls: urls,
                            fallback: issuer.isEmpty ? accountName : issuer
                        )
                        drafts.append(.totp(LocalTotpEntryDraft(
                            title: title,
                            secret: secret,
                            issuer: issuer.isEmpty ? (accountName.isEmpty ? title : accountName) : issuer,
                            accountName: accountName,
                            period: normalizedPeriod(totp.period),
                            digits: normalizedDigits(totp.digits),
                            algorithm: normalizedAlgorithm(totp.algorithm),
                            otpType: "TOTP",
                            counter: 0
                        )))
                        totpCount += 1
                    case .unsupported:
                        unsupportedCredentialCount += 1
                    }
                }
            }
        }

        return CredentialExchangeImportPlan(
            drafts: drafts,
            sourceAccountCount: accounts.count,
            sourceItemCount: sourceItemCount,
            passwordCount: passwordCount,
            totpCount: totpCount,
            skippedDuplicateCount: skippedDuplicateCount,
            unsupportedCredentialCount: unsupportedCredentialCount,
            invalidCredentialCount: invalidCredentialCount
        )
    }

    public static func exportPlan(
        loginEntries: [LocalLoginEntry],
        totpEntries: [LocalTotpEntry]
    ) -> CredentialExchangeExportPlan {
        var items: [CredentialExchangeItem] = []
        var passwordCount = 0
        var totpCount = 0
        var skippedCount = 0

        for entry in loginEntries {
            let userName = entry.username
            guard !userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !entry.password.isEmpty else {
                skippedCount += 1
                continue
            }
            let url = entry.url.trimmingCharacters(in: .whitespacesAndNewlines)
            let urls = url.isEmpty ? [] : [url]
            items.append(CredentialExchangeItem(
                title: resolvedTitle(entry.title, urls: urls, fallback: userName),
                urls: urls,
                favorite: entry.favorite,
                credentials: [.password(CredentialExchangePassword(userName: userName, password: entry.password))]
            ))
            passwordCount += 1
        }

        for entry in totpEntries {
            guard let secret = Base32.normalizedSecret(entry.secret) else {
                skippedCount += 1
                continue
            }
            let accountName = entry.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
            let issuer = entry.issuer.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(CredentialExchangeItem(
                title: resolvedTitle(entry.title, urls: [], fallback: issuer.isEmpty ? accountName : issuer),
                urls: [],
                favorite: entry.favorite,
                credentials: [.totp(CredentialExchangeTOTP(
                    secret: secret,
                    period: normalizedPeriod(entry.period),
                    digits: normalizedDigits(entry.digits),
                    accountName: accountName,
                    issuer: issuer,
                    algorithm: normalizedAlgorithm(entry.algorithm)
                ))]
            ))
            totpCount += 1
        }

        return CredentialExchangeExportPlan(
            account: CredentialExchangeAccount(
                userName: "Monica",
                email: "",
                fullName: nil,
                items: items
            ),
            passwordCount: passwordCount,
            totpCount: totpCount,
            skippedCount: skippedCount
        )
    }

    private struct LoginIdentity: Hashable {
        let urlKey: String
        let userName: String
        let password: String
    }

    private struct TOTPIdentity: Hashable {
        let secret: String
        let accountName: String
    }

    private static func resolvedTitle(_ title: String, urls: [String], fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if let first = urls.first,
           let host = URLComponents(string: first)?.host?.lowercased(),
           !host.isEmpty {
            return host
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? "未命名条目" : trimmedFallback
    }

    private static func normalizedPeriod(_ value: UInt32) -> UInt32 {
        guard value >= 1, value <= 3600 else { return 30 }
        return value
    }

    private static func normalizedDigits(_ value: UInt32) -> UInt32 {
        value == 8 ? 8 : 6
    }

    private static func normalizedAlgorithm(_ value: String) -> String {
        switch value.uppercased() {
        case "SHA256":
            return "SHA256"
        case "SHA512":
            return "SHA512"
        default:
            return "SHA1"
        }
    }
}
