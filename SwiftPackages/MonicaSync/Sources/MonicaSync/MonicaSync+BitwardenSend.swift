// MARK: - Bitwarden Send 链接与接收

import Foundation

/// Bitwarden Send 的可分享链接。
///
/// 链接形式：`<serverBaseURL>/#/send/<accessID>/<base64url(keyMaterial)>`
/// key material 是发送端随机生成、只存在于链接片段（#）里的解密密钥，
/// 因此绝不能出现在日志或 UI 摘要中；`redactedSummary` 只保留 accessID 的短前缀。
public struct BitwardenSendLink: Sendable, Equatable {
    public let accessID: String
    public let keyMaterial: Data

    public init(accessID: String, keyMaterial: Data) {
        self.accessID = accessID
        self.keyMaterial = keyMaterial
    }

    /// 拼出可直接发给对方的完整链接。
    /// `serverBaseURL` 用 web vault 地址（如 `https://vault.bitwarden.com`），
    /// 不是 API 地址（`https://api.bitwarden.com`）——两者域名不同。
    public func url(serverBaseURL: URL) -> URL? {
        // 手工拼接而不是用 URLComponents.fragment：后者会生成 `host#/send/...`，
        // 丢掉 Bitwarden web vault 要求的斜杠（`host/#/send/...`）。
        var base = serverBaseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let key = keyMaterial.base64URLEncodedString()
        return URL(string: "\(base)/#/send/\(accessID)/\(key)")
    }

    /// 从用户粘贴的链接里还原 accessID 与 key material。
    public static func parse(urlString: String, serverBaseURL: URL) -> BitwardenSendLink? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        // 支持完整链接，也支持只粘贴 fragment 内容（#/send/xxx/key 里的后两段）
        let fragment = url.fragment ?? trimmed
        let segments = fragment
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard segments.count >= 2 else { return nil }
        let keySegment = segments[segments.count - 1]
        let accessIDSegment = segments[segments.count - 2]
        // 必须形如 .../send/<accessID>/<key>，避免误吞任意 URL
        guard segments.count >= 3, segments[segments.count - 3] == "send" else { return nil }
        guard let keyMaterial = Data(bitwardenBase64Encoded: keySegment), keyMaterial.count == 16 else {
            return nil
        }
        guard !accessIDSegment.isEmpty else { return nil }
        _ = serverBaseURL // 保留参数以便未来校验 host 一致
        return BitwardenSendLink(accessID: accessIDSegment, keyMaterial: keyMaterial)
    }

    public var redactedSummary: String {
        let prefix = String(accessID.prefix(6))
        return "Bitwarden Send 链接 \(prefix)…"
    }
}

/// 从远端取回的 Send 内容（已解密）。
public struct BitwardenReceivedSend: Sendable, Equatable {
    public let title: String
    public let text: String
    public let notes: String?
    public let expiresAt: String
    public let maxViews: Int
    public let remainingViews: Int?
    public let requiresPassword: Bool

    public init(
        title: String,
        text: String,
        notes: String? = nil,
        expiresAt: String = "",
        maxViews: Int = 1,
        remainingViews: Int? = nil,
        requiresPassword: Bool = false
    ) {
        self.title = title
        self.text = text
        self.notes = notes
        self.expiresAt = expiresAt
        self.maxViews = maxViews
        self.remainingViews = remainingViews
        self.requiresPassword = requiresPassword
    }

    public var redactedSummary: String {
        "Bitwarden Send \(sanitizedBitwardenTitle(title)) \(maxViews) 次"
    }
}

/// 匿名接收 Send 所需的请求参数。
public struct BitwardenSendFetchRequest: Sendable, Equatable {
    public let link: BitwardenSendLink
    /// 访问密码；nil 表示该 Send 没有密码保护。
    public let password: String?
    /// 服务端 API 地址（用于拼接 `/sends/access/<accessID>`）。
    public let apiURL: URL

    public init(link: BitwardenSendLink, password: String? = nil, apiURL: URL) {
        self.link = link
        self.password = password
        self.apiURL = apiURL
    }
}

/// 创建文本型 Send 的请求参数。
public struct BitwardenTextSendCreateRequest: Sendable, Equatable {
    public let title: String
    public let text: String
    public let notes: String?
    /// 过期时间（ISO8601）；空字符串表示永不过期。
    public let expiresAt: String
    /// 最大查看次数；0 或负数表示不限制。
    public let maxViews: Int
    /// 访问密码；nil 表示无密码保护。
    public let password: String?
    public let hideEmail: Bool

    public init(
        title: String,
        text: String,
        notes: String? = nil,
        expiresAt: String = "",
        maxViews: Int = 1,
        password: String? = nil,
        hideEmail: Bool = false
    ) {
        self.title = title
        self.text = text
        self.notes = notes
        self.expiresAt = expiresAt
        self.maxViews = maxViews
        self.password = password
        self.hideEmail = hideEmail
    }
}

/// 创建结果。`link` 是唯一一次能拿到分享链接的机会——
/// key material 只在这里返回，之后服务端与本地都不再持有它。
public struct BitwardenTextSendCreateResult: Sendable, Equatable {
    public let remoteID: String
    public let link: BitwardenSendLink?
    public let revision: String

    public init(remoteID: String, link: BitwardenSendLink?, revision: String = "") {
        self.remoteID = remoteID
        self.link = link
        self.revision = revision
    }

    public var redactedSummary: String {
        "Bitwarden Send 已创建，链接\(link == nil ? "不可用" : "可分享")"
    }
}
