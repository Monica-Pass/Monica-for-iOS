import Foundation

/// 登录条目的一条历史密码：`changedAt` 是这次修改生效的时间，`password` 是上一份密文。
///
/// 历史条目和其它登录字段一样只存在于 Vault 加密载荷里，不写 UserDefaults、日志或缓存。
public struct LocalLoginPasswordHistoryEntry: Sendable, Equatable, Identifiable, Codable, Hashable {
    public let id: String
    public let changedAt: Date
    public let password: String

    public init(id: String = UUID().uuidString, changedAt: Date, password: String) {
        self.id = id
        self.changedAt = changedAt
        self.password = password
    }
}

/// 多 URL 的规范化与校验。
///
/// 规范化只做「去空白、去空、保序去重」这类不会改变用户语义的事情；
/// 校验只用于编辑器内联提示和详情页决定是否渲染可点击链接，不会拒绝保存，
/// 以免旧库里已有的非常规网址在编辑标题时突然无法保存。
public enum LoginEntryURLRules {
    /// 编辑器最多展示的 URL 行数（主 URL + 追加行）。
    public static let maximumURLCount = 20

    public enum Issue: Sendable, Equatable {
        /// 该行还没填内容，编辑器不展示错误。
        case empty
        /// 只接受 http/https 链接。
        case unsupportedScheme(String)
        /// 缺少主机名。
        case missingHost
        /// 既不是完整链接，也不像 `example.com/path` 这样的主机名。
        case malformed
    }

    /// 有序去重：保留第一次出现的顺序，去掉首尾空白与空串。
    public static func normalizedURLs(primary: String, additional: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for candidate in [primary] + additional {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    public static func normalizedURLs(_ candidates: [String]) -> [String] {
        normalizedURLs(primary: candidates.first ?? "", additional: Array(candidates.dropFirst()))
    }

    /// 返回 nil 表示合法。
    public static func issue(for candidate: String) -> Issue? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return .malformed }

        if let range = trimmed.range(of: "://") {
            let scheme = String(trimmed[trimmed.startIndex..<range.lowerBound]).lowercased()
            guard scheme == "http" || scheme == "https" else {
                return .unsupportedScheme(scheme)
            }
            guard let components = URLComponents(string: trimmed),
                  let host = components.host,
                  !host.isEmpty
            else {
                return .missingHost
            }
            return nil
        }

        // 也接受未写 scheme 的 `example.com/path` 形式，避免用户补全负担。
        let hostPortion = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let host = hostPortion.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        guard !host.isEmpty,
              host.contains("."),
              !host.hasPrefix("."),
              !host.hasSuffix("."),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        else {
            return .malformed
        }
        return nil
    }

    public static func isValid(_ candidate: String) -> Bool {
        issue(for: candidate) == nil
    }
}

/// 密码历史的写入策略：只有当密码确实变化时，才把上一份密文追加为一条历史。
public enum LoginPasswordHistoryPolicy {
    public static let maximumEntries = 30

    /// - Parameters:
    ///   - previousPassword: 保存前Vault 里的密码。
    ///   - newPassword: 本次要保存的密码。
    ///   - history: 调用方给出的历史（UI 删除单条/清空后传回的列表）。
    /// - Returns: 需要落盘的最终历史，最新的一条在最前面。
    public static func appending(
        previousPassword: String,
        newPassword: String,
        history: [LocalLoginPasswordHistoryEntry],
        now: Date = Date()
    ) -> [LocalLoginPasswordHistoryEntry] {
        let sanitized = sanitizedHistory(history)
        guard !previousPassword.isEmpty, previousPassword != newPassword else {
            return sanitized
        }
        if sanitized.first?.password == previousPassword {
            return sanitized
        }
        let appended = [LocalLoginPasswordHistoryEntry(changedAt: now, password: previousPassword)] + sanitized
        return Array(appended.prefix(maximumEntries))
    }

    public static func removing(
        id: LocalLoginPasswordHistoryEntry.ID,
        from history: [LocalLoginPasswordHistoryEntry]
    ) -> [LocalLoginPasswordHistoryEntry] {
        history.filter { $0.id != id }
    }

    /// 去掉空密码、连续重复的密文，并限制总量，避免历史无界增长。
    public static func sanitizedHistory(_ history: [LocalLoginPasswordHistoryEntry]) -> [LocalLoginPasswordHistoryEntry] {
        var result: [LocalLoginPasswordHistoryEntry] = []
        for entry in history where !entry.password.isEmpty {
            if result.last?.password == entry.password {
                continue
            }
            result.append(entry)
        }
        return Array(result.prefix(maximumEntries))
    }
}

extension LocalLoginEntryDraft {
    /// 用新的历史替换草稿里的历史，其余字段保持不变。
    public func withPasswordHistory(_ history: [LocalLoginPasswordHistoryEntry]) -> LocalLoginEntryDraft {
        LocalLoginEntryDraft(
            title: title,
            username: username,
            account: account,
            password: password,
            url: url,
            notes: notes,
            urls: urls,
            appBundleID: appBundleID,
            appName: appName,
            passwordHistory: history
        )
    }

    /// 用新的有序 URL 列表替换草稿里的 URL 字段（首项成为主 URL）。
    public func withURLs(_ urls: [String]) -> LocalLoginEntryDraft {
        LocalLoginEntryDraft(
            title: title,
            username: username,
            account: account,
            password: password,
            url: urls.first ?? "",
            notes: notes,
            urls: urls,
            appBundleID: appBundleID,
            appName: appName,
            passwordHistory: passwordHistory
        )
    }
}
