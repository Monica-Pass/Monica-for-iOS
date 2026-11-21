import Foundation

/// Steam Guard 条目的共享密钥校验工具。
///
/// Steam 客户端导出的 `shared_secret` 是 base64 文本；这里只做格式校验与规范化，
/// 不含任何网络或登录逻辑。
public enum SteamSharedSecretValidator {
    public static let minimumKeyLength = 10

    /// 去掉空白、兼容 URL-safe 字符并补齐 `=` 填充。
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

    public static func decodedKey(_ rawValue: String) -> Data? {
        let normalized = normalizedBase64(rawValue)
        guard !normalized.isEmpty,
              let decoded = Data(base64Encoded: normalized),
              decoded.count >= minimumKeyLength else {
            return nil
        }
        return decoded
    }

    public static func isValid(_ rawValue: String) -> Bool {
        decodedKey(rawValue) != nil
    }
}

/// Steam Guard 条目草稿。
public struct LocalSteamEntryDraft: Sendable, Equatable {
    public var title: String
    public var accountName: String
    public var steamID: String
    /// base64 文本形式的 `shared_secret`，只在加密 Vault payload 中保存。
    public var sharedSecret: String
    public var issuer: String
    public var notes: String

    public init(
        title: String,
        accountName: String = "",
        steamID: String = "",
        sharedSecret: String,
        issuer: String = "Steam",
        notes: String = ""
    ) {
        self.title = title
        self.accountName = accountName
        self.steamID = steamID
        self.sharedSecret = sharedSecret
        self.issuer = issuer
        self.notes = notes
    }
}

/// Steam Guard 条目。
public struct LocalSteamEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public var title: String
    public var accountName: String
    public var steamID: String
    /// base64 文本形式的 `shared_secret`。
    public var sharedSecret: String
    public var issuer: String
    public var notes: String
    public var favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        accountName: String = "",
        steamID: String = "",
        sharedSecret: String,
        issuer: String = "Steam",
        notes: String = "",
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.accountName = accountName
        self.steamID = steamID
        self.sharedSecret = sharedSecret
        self.issuer = issuer
        self.notes = notes
        self.favorite = favorite
    }
}

extension LocalSteamEntry: CustomStringConvertible {
    /// 任何日志或错误文案都不应包含共享密钥。
    public var description: String {
        "LocalSteamEntry(id: \(id), title: \(title), account: \(accountName), secret: <redacted>)"
    }
}

extension LocalSteamEntryDraft: CustomStringConvertible {
    public var description: String {
        "LocalSteamEntryDraft(title: \(title), account: \(accountName), secret: <redacted>)"
    }
}

/// `LocalSteamEntry` 在 MDBX parity payload 中的编解码。
///
/// 解码保持「永不失败」：历史数据或其它客户端写入的 payload 缺少字段时回退为
/// 空字符串，由列表 UI 显示「密钥不可用」；写入路径则通过
/// `SteamSharedSecretValidator` 严格校验，畸形密钥不会被保存。
public enum SteamEntryPayloadCodec {
    public static let schemaVersion = 1

    public enum Key {
        public static let schemaVersion = "schemaVersion"
        public static let accountName = "accountName"
        public static let steamID = "steamID"
        public static let sharedSecret = "sharedSecret"
        public static let issuer = "issuer"
        public static let notes = "notes"
    }

    public static func encoded(_ draft: LocalSteamEntryDraft) -> [String: Any] {
        [
            Key.schemaVersion: schemaVersion,
            Key.accountName: draft.accountName,
            Key.steamID: draft.steamID,
            Key.sharedSecret: SteamSharedSecretValidator.normalizedBase64(draft.sharedSecret),
            Key.issuer: draft.issuer,
            Key.notes: draft.notes
        ]
    }

    public static func decoded(
        _ payload: [String: Any],
        entryID: String,
        projectID: String,
        title: String,
        favorite: Bool
    ) -> LocalSteamEntry {
        let secret = payload[Key.sharedSecret] as? String ?? ""
        let issuer = (payload[Key.issuer] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalSteamEntry(
            id: entryID,
            projectID: projectID,
            title: title,
            accountName: payload[Key.accountName] as? String ?? "",
            steamID: payload[Key.steamID] as? String ?? "",
            sharedSecret: SteamSharedSecretValidator.isValid(secret)
                ? SteamSharedSecretValidator.normalizedBase64(secret)
                : "",
            issuer: issuer.isEmpty ? "Steam" : issuer,
            notes: payload[Key.notes] as? String ?? "",
            favorite: favorite
        )
    }
}

/// Steam 备份互通需要的 base32 转换。
///
/// Android 端把 Steam 条目存成 `otpType = STEAM` 的 TOTP 条目：`secret` 是
/// base32，`steamSharedSecretBase64` 保留原始 base64。这里提供最小的 base32
/// 编解码，用于把 base64 密钥写成 Android 能读取的 `secret`，以及在没有
/// `steamSharedSecretBase64` 时回退解码。
enum SteamBase32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var output = ""
        var buffer = 0
        var bitsLeft = 0

        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                bitsLeft -= 5
                output.append(alphabet[(buffer >> bitsLeft) & 0x1f])
                buffer &= (1 << bitsLeft) - 1
            }
        }

        if bitsLeft > 0 {
            output.append(alphabet[(buffer << (5 - bitsLeft)) & 0x1f])
        }
        return output
    }

    static func decode(_ value: String) -> Data? {
        let normalized = value
            .uppercased()
            .filter { !$0.isWhitespace && $0 != "=" }
        guard !normalized.isEmpty else {
            return nil
        }

        var buffer = 0
        var bitsLeft = 0
        var bytes: [UInt8] = []

        for character in normalized {
            guard let index = alphabet.firstIndex(of: character) else {
                return nil
            }
            buffer = (buffer << 5) | index
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                bytes.append(UInt8((buffer >> bitsLeft) & 0xff))
                buffer &= (1 << bitsLeft) - 1
            }
        }

        return bytes.isEmpty ? nil : Data(bytes)
    }
}

extension LocalSteamEntryDraft {
    /// 构造 Android 备份中 `itemData` 的 JSON 对象（TOTP 载体 + STEAM 标记）。
    static func backupItemData(from draft: LocalSteamEntryDraft) -> [String: Any] {
        let normalizedSecret = SteamSharedSecretValidator.normalizedBase64(draft.sharedSecret)
        let keyData = SteamSharedSecretValidator.decodedKey(normalizedSecret) ?? Data()
        return [
            "secret": SteamBase32.encode(keyData),
            "issuer": draft.issuer,
            "accountName": draft.accountName,
            "period": 30,
            "digits": 5,
            "algorithm": "SHA1",
            "otpType": "STEAM",
            "counter": 0,
            "steamSharedSecretBase64": normalizedSecret
        ]
    }

    /// 从 Android 备份 / maFile 形态的 `itemData` 还原 Steam 草稿。
    ///
    /// 必须同时满足 `otpType == STEAM`（或显式带 `steamSharedSecretBase64`）
    /// 与可用密钥，否则返回 nil，交由调用方按普通 TOTP 处理。
    static func steamDraft(
        title: String,
        issuer: String,
        accountName: String,
        itemData: [String: Any]
    ) -> LocalSteamEntryDraft? {
        let otpType = (itemData["otpType"] as? String ?? "").uppercased()
        let base64Secret = itemData["steamSharedSecretBase64"] as? String ?? ""
        guard otpType == "STEAM" || !base64Secret.isEmpty else {
            return nil
        }

        let secret: String
        if SteamSharedSecretValidator.isValid(base64Secret) {
            secret = SteamSharedSecretValidator.normalizedBase64(base64Secret)
        } else if let decoded = SteamBase32.decode(itemData["secret"] as? String ?? "") {
            secret = decoded.base64EncodedString()
        } else {
            return nil
        }
        guard SteamSharedSecretValidator.isValid(secret) else {
            return nil
        }

        let resolvedIssuer = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalSteamEntryDraft(
            title: title,
            accountName: accountName,
            sharedSecret: secret,
            issuer: resolvedIssuer.isEmpty ? "Steam" : resolvedIssuer,
            notes: itemData["notes"] as? String ?? ""
        )
    }
}
