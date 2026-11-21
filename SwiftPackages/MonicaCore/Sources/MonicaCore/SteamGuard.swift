import CryptoKit
import Foundation

/// Steam Guard 专属的验证码错误。
///
/// Steam Guard 不是 RFC 6238 TOTP：字母表、位数、密钥编码都与 TOTP 不同，
/// 因此这里使用独立的错误类型，避免把 Steam 的失败误报成 TOTP 的失败。
public enum SteamGuardError: Error, Sendable, Equatable {
    case emptySecret
    case invalidBase64Secret
    case invalidTimestamp
    case invalidImportPayload
    case missingSharedSecret
    case invalidSteamGuardURI
}

/// 校验通过的 Steam `shared_secret`。
///
/// Steam 客户端导出的 `shared_secret` 是 base64 文本（20 字节 HMAC 密钥的
/// base64 编码），不是 Base32。这里在构造时就完成规范化与解码，后续生成码时
/// 不再重复容错。
public struct SteamGuardSecret: Sendable, Equatable, CustomStringConvertible {
    /// 规范化后的 base64 文本（可安全写回 Vault，但不应写日志）。
    public let base64: String
    /// 解码后的 HMAC 密钥字节。
    public let keyData: Data

    public init(base64 value: String) throws {
        let normalized = SteamGuardSecret.normalizedBase64(value)
        guard !normalized.isEmpty else {
            throw SteamGuardError.emptySecret
        }
        guard let decoded = Data(steamGuardBase64Encoded: normalized), decoded.count >= SteamGuardSecret.minimumKeyLength else {
            throw SteamGuardError.invalidBase64Secret
        }
        self.base64 = normalized
        self.keyData = decoded
    }

    /// Steam 官方 `shared_secret` 为 20 字节；这里留出下限而非精确匹配，
    /// 以便兼容其它工具导出的等价密钥，同时仍拒绝空密钥和明显截断的输入。
    public static let minimumKeyLength = 10

    public var description: String {
        "SteamGuardSecret(<redacted>, \(keyData.count) bytes)"
    }

    /// 严格版 base64 规范化：去掉所有空白与换行，兼容 URL-safe 字符与缺失的 `=` 填充，
    /// 但拒绝任何非法字符。
    public static func normalizedBase64(_ rawValue: String) -> String {
        let stripped = rawValue.filter { !$0.isWhitespace }
        guard !stripped.isEmpty else {
            return ""
        }
        let replaced = stripped
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingCount = (4 - replaced.count % 4) % 4
        return replaced + String(repeating: "=", count: paddingCount)
    }

    public static func isValidBase64Secret(_ rawValue: String) -> Bool {
        (try? SteamGuardSecret(base64: rawValue)) != nil
    }
}

/// 一次 Steam Guard 生成结果。
public struct SteamGuardCode: Sendable, Equatable, CustomStringConvertible {
    /// 5 位 Steam Guard 码。
    public let code: String
    /// 距离当前 30 秒窗口结束的剩余秒数，范围 1...30。
    public let remainingSeconds: Int
    /// 本窗口起始时间（含）。
    public let validFrom: Date
    /// 本窗口结束时间（不含）。
    public let validUntil: Date

    public var description: String {
        "SteamGuardCode(remainingSeconds: \(remainingSeconds))"
    }
}

/// Steam Guard 5 位字母验证码生成器。
///
/// 算法：`HMAC-SHA1(sharedSecret, counter)`，取动态截断后的 31 位整数，
/// 连续 5 次对 26 取模并映射到 Steam 专属字母表（大整数低位先生成）。
public enum SteamGuardGenerator {
    /// Steam Guard 专属字母表，刻意不含元音与 0/1。
    public static let alphabet = "23456789BCDFGHJKMNPQRTVWXY"
    /// 时间步长固定 30 秒。
    public static let period: TimeInterval = 30
    /// Steam Guard 码固定 5 位。
    public static let codeLength = 5

    /// 使用经过校验的密钥生成当前窗口的验证码。
    public static func code(for secret: SteamGuardSecret, at date: Date = Date()) -> SteamGuardCode {
        let timestamp = date.timeIntervalSince1970
        let counter = Self.counter(for: timestamp)
        let windowStart = Double(counter) * period
        let digits = dynamicTruncate(hmacSHA1(secret: secret.keyData, counter: counter))

        var remainingValue = digits
        var characters: [Character] = []
        characters.reserveCapacity(codeLength)
        let alphabetCharacters = Array(alphabet)
        for _ in 0..<codeLength {
            characters.append(alphabetCharacters[Int(remainingValue % UInt32(alphabetCharacters.count))])
            remainingValue /= UInt32(alphabetCharacters.count)
        }

        return SteamGuardCode(
            code: String(characters),
            remainingSeconds: remainingSeconds(at: timestamp),
            validFrom: Date(timeIntervalSince1970: windowStart),
            validUntil: Date(timeIntervalSince1970: windowStart + period)
        )
    }

    /// 便捷入口：直接传入 base64 文本的 `shared_secret`。
    public static func code(base64Secret: String, at date: Date = Date()) throws -> SteamGuardCode {
        let secret = try SteamGuardSecret(base64: base64Secret)
        return code(for: secret, at: date)
    }

    /// 距离当前 30 秒窗口结束的剩余秒数，范围 1...30。
    public static func remainingSeconds(at date: Date = Date()) -> Int {
        remainingSeconds(at: date.timeIntervalSince1970)
    }

    /// 距离当前 30 秒窗口结束的剩余秒数（时间戳版本）。
    public static func remainingSeconds(at timestamp: TimeInterval) -> Int {
        guard timestamp.isFinite else {
            return codeLength
        }
        let remainder = timestamp.truncatingRemainder(dividingBy: period)
        let remaining = Int((period - remainder).rounded(.up))
        return min(Int(period), max(1, remaining))
    }

    /// 当前时间对应的 HOTP 计数器。
    public static func counter(for timestamp: TimeInterval) -> UInt64 {
        guard timestamp.isFinite, timestamp > 0 else {
            return 0
        }
        return UInt64(timestamp / period)
    }

    static func hmacSHA1(secret: Data, counter: UInt64) -> Data {
        var bigEndianCounter = counter.bigEndian
        let counterData = Data(bytes: &bigEndianCounter, count: MemoryLayout<UInt64>.size)
        return Data(HMAC<Insecure.SHA1>.authenticationCode(
            for: counterData,
            using: SymmetricKey(data: secret)
        ))
    }

    /// RFC 4226 动态截断，结果 31 位（最高位清零）。
    static func dynamicTruncate(_ hmac: Data) -> UInt32 {
        let offset = Int(hmac[hmac.count - 1] & 0x0f)
        return (UInt32(hmac[offset] & 0x7f) << 24)
            | (UInt32(hmac[offset + 1]) << 16)
            | (UInt32(hmac[offset + 2]) << 8)
            | UInt32(hmac[offset + 3])
    }
}

/// Steam maFile / `steamguard://` 的离线导入结果。
///
/// 只读取生成验证码所必需的字段；`identity_secret`、登录 cookie、token 等
/// 一律忽略，也不会被保存。
public struct SteamGuardImportDraft: Sendable, Equatable, CustomStringConvertible {
    public let accountName: String
    public let steamID: String
    public let sharedSecretBase64: String
    public let issuer: String

    public init(accountName: String, steamID: String, sharedSecretBase64: String, issuer: String = "Steam") {
        self.accountName = accountName
        self.steamID = steamID
        self.sharedSecretBase64 = sharedSecretBase64
        self.issuer = issuer
    }

    /// 建议的条目标题。
    public var suggestedTitle: String {
        let normalizedAccount = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedAccount.isEmpty ? issuer : "\(issuer) · \(normalizedAccount)"
    }

    /// 日志与错误文案可用的脱敏描述。
    public var redactedSummary: String {
        let normalizedAccount = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedAccount.isEmpty ? issuer : normalizedAccount
    }

    public var description: String {
        "SteamGuardImportDraft(account: \(redactedSummary), secret: <redacted>)"
    }
}

/// Steam maFile（SDA 导出 JSON）与 `steamguard://` URI 的解析器。
public enum SteamGuardImportParser {
    /// 解析 maFile / SDA 导出的 JSON 数据。
    public static func parse(_ data: Data) throws -> SteamGuardImportDraft {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SteamGuardError.invalidImportPayload
        }
        guard let rawSecret = jsonString(root, "shared_secret", "sharedSecret") else {
            throw SteamGuardError.missingSharedSecret
        }
        let secret = try SteamGuardSecret(base64: rawSecret)
        let accountName = jsonString(root, "account_name", "accountName")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let steamID = jsonString(root, "steamid", "steam_id", "steamID")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SteamGuardImportDraft(
            accountName: accountName,
            steamID: steamID,
            sharedSecretBase64: secret.base64
        )
    }

    /// 解析文本：优先按 JSON 解析，其次按 `steamguard://` / `steam://` URI 解析。
    public static func parse(text: String) throws -> SteamGuardImportDraft {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SteamGuardError.invalidImportPayload
        }
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) {
            return try parse(data)
        }
        return try parseURI(trimmed)
    }

    /// 解析 `steamguard://<base64 secret>?account=<name>&steamid=<id>&issuer=Steam`
    /// 以及 Bitwarden 风格的 `steam://<base64 secret>`。
    public static func parseURI(_ value: String) throws -> SteamGuardImportDraft {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "steamguard" || scheme == "steam" else {
            throw SteamGuardError.invalidSteamGuardURI
        }

        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name.lowercased(), $0) }
            }
        )

        // 允许两种写法：`steamguard://<secret>`（host 承载密钥）与 `steamguard:?secret=...`。
        let hostSecret = components.host ?? ""
        let rawSecret = (query["secret"] ?? query["shared_secret"] ?? hostSecret)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawSecret.isEmpty else {
            throw SteamGuardError.missingSharedSecret
        }
        let secret: SteamGuardSecret
        do {
            secret = try SteamGuardSecret(base64: rawSecret)
        } catch {
            throw SteamGuardError.missingSharedSecret
        }

        let accountName = (query["account"] ?? query["account_name"] ?? query["name"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let steamID = (query["steamid"] ?? query["steam_id"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let issuer = (query["issuer"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return SteamGuardImportDraft(
            accountName: accountName,
            steamID: steamID,
            sharedSecretBase64: secret.base64,
            issuer: issuer.isEmpty ? "Steam" : issuer
        )
    }

    private static func jsonString(_ json: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = json[key] as? String {
                return value
            }
            if let number = json[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }
}

private extension Data {
    init?(steamGuardBase64Encoded value: String) {
        self.init(base64Encoded: value)
    }
}
