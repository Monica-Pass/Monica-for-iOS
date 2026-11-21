// MARK: - SSO 条目：类型、URL 校验、仓库与 MDBX 引擎实现

import Foundation
import MonicaMDBX

/// SSO 条目记录的身份提供方。
///
/// 这里只保存「用户手动录入的 SSO 配置元数据」，不涉及任何 OAuth/OIDC 令牌交换：
/// Monica 不会、也无法从第三方网站自动提取 SSO 会话或 cookie。
public enum SSOProvider: String, Sendable, CaseIterable, Equatable, Hashable {
    case google
    case microsoft
    case apple
    case github
    case okta
    case auth0
    case onelogin
    case keycloak
    case custom

    public var displayName: String {
        switch self {
        case .google:
            return "Google"
        case .microsoft:
            return "Microsoft"
        case .apple:
            return "Apple"
        case .github:
            return "GitHub"
        case .okta:
            return "Okta"
        case .auth0:
            return "Auth0"
        case .onelogin:
            return "OneLogin"
        case .keycloak:
            return "Keycloak"
        case .custom:
            return "自建 / 其他 IdP"
        }
    }

    /// Android 端 `SsoProvider` 枚举名，用于备份互通（Android `LoginType.kt`）。
    public var androidName: String {
        switch self {
        case .google:
            return "GOOGLE"
        case .microsoft:
            return "MICROSOFT"
        case .apple:
            return "APPLE"
        case .github:
            return "GITHUB"
        case .okta:
            return "OKTA"
        case .auth0:
            return "AUTH0"
        case .onelogin:
            return "ONELOGIN"
        case .keycloak:
            return "KEYCLOAK"
        case .custom:
            return "OTHER"
        }
    }

    /// OIDC issuer 的常见默认值；为空表示该提供方没有统一的 issuer。
    public var defaultIssuer: String {
        switch self {
        case .google:
            return "https://accounts.google.com"
        case .microsoft:
            return "https://login.microsoftonline.com/common/v2.0"
        case .apple:
            return "https://appleid.apple.com"
        case .github:
            return "https://github.com"
        case .okta, .auth0, .onelogin, .keycloak, .custom:
            return ""
        }
    }

    /// 各提供方的登录入口，仅作为「打开正规登录地址」的默认值。
    public var defaultLoginURL: String {
        switch self {
        case .google:
            return "https://accounts.google.com/"
        case .microsoft:
            return "https://login.microsoftonline.com/"
        case .apple:
            return "https://appleid.apple.com/"
        case .github:
            return "https://github.com/login"
        case .okta, .auth0, .onelogin, .keycloak, .custom:
            return ""
        }
    }

    public var systemImageName: String {
        switch self {
        case .google:
            return "g.circle.fill"
        case .microsoft:
            return "square.grid.2x2.fill"
        case .apple:
            return "apple.logo"
        case .github:
            return "chevron.left.forwardslash.chevron.right"
        case .okta, .auth0, .onelogin, .keycloak:
            return "key.fill"
        case .custom:
            return "building.2.fill"
        }
    }

    /// 未知的备份值一律回落到 `.custom`，保证旧/新备份互读不会失败。
    public static func fromAndroidName(_ rawValue: String) -> SSOProvider {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return SSOProvider.allCases.first { $0.androidName == normalized } ?? .custom
    }

    /// 解析自身存储的 rawValue（parity payload / CSV 列）。
    public static func fromStoredValue(_ rawValue: String) -> SSOProvider {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let provider = SSOProvider(rawValue: normalized) {
            return provider
        }
        return fromAndroidName(normalized)
    }
}

/// SSO 登录地址校验错误。
public enum SSOEntryURLError: Error, Sendable, Equatable, LocalizedError {
    case empty
    case malformed
    case unsupportedScheme(String)
    case missingHost
    case insecureScheme

    public var errorDescription: String? {
        message
    }

    public var message: String {
        switch self {
        case .empty:
            return String(localized: "登录地址不能为空")
        case .malformed:
            return String(localized: "登录地址格式不正确")
        case let .unsupportedScheme(scheme):
            return String(localized: "不支持的地址协议：\(scheme)")
        case .missingHost:
            return String(localized: "登录地址缺少主机名")
        case .insecureScheme:
            return String(localized: "该字段只允许 https 地址")
        }
    }
}

/// 只做「记录与展示」的 SSO 条目，外部跳转前必须经过这里的校验。
///
/// 规则：只放行 `http` / `https`，且必须带主机名；空串、`javascript:`、
/// `file:`、`data:` 以及任何其它 scheme 一律拒绝。issuer 额外要求 https。
public enum SSOEntryURLValidator {
    public static let allowedSchemes: Set<String> = ["http", "https"]

    public static func error(for rawValue: String) -> SSOEntryURLError? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .empty
        }
        guard !containsForbiddenCharacters(trimmed) else {
            return .malformed
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              !scheme.isEmpty
        else {
            return .malformed
        }
        let normalizedScheme = scheme.lowercased()
        guard allowedSchemes.contains(normalizedScheme) else {
            return .unsupportedScheme(normalizedScheme)
        }
        let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !host.isEmpty else {
            return .missingHost
        }
        return nil
    }

    public static func sanitizedURL(from rawValue: String) -> URL? {
        guard error(for: rawValue) == nil,
              let components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        return components.url
    }

    public static func normalizedString(from rawValue: String) -> String? {
        sanitizedURL(from: rawValue)?.absoluteString
    }

    /// issuer 只接受 https（OIDC issuer 规范要求）。
    public static func isSecureIssuer(_ rawValue: String) -> Bool {
        guard let url = sanitizedURL(from: rawValue) else {
            return false
        }
        return url.scheme?.lowercased() == "https"
    }

    public static func issuerError(for rawValue: String) -> SSOEntryURLError? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let error = error(for: trimmed) {
            return error
        }
        return isSecureIssuer(trimmed) ? nil : .insecureScheme
    }

    private static func containsForbiddenCharacters(_ value: String) -> Bool {
        if value.contains("\n") || value.contains("\r") || value.contains("\t") {
            return true
        }
        if value.contains(" ") {
            return true
        }
        return value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }
}

public struct LocalSSOEntryDraft: Sendable, Equatable {
    public let title: String
    public let provider: SSOProvider
    /// 自建 / 自定义 IdP 的显示名称，覆盖 `provider.displayName`。
    public let providerName: String
    public let issuer: String
    public let accountName: String
    public let loginURL: String
    /// 关联的登录条目 ID；条目被真删除后这里会残留，读取方必须能平稳降级。
    public let linkedLoginEntryID: String?
    public let notes: String
    /// 可选的附加凭据（client secret / 备注型凭据）。加密后随条目一起落库。
    public let secret: String

    public let metadata: VaultEntryMetadata

    public init(
        title: String,
        provider: SSOProvider = .custom,
        providerName: String = "",
        issuer: String = "",
        accountName: String = "",
        loginURL: String = "",
        linkedLoginEntryID: String? = nil,
        notes: String = "",
        secret: String = "",
        metadata: VaultEntryMetadata = .empty
    ) {
        self.title = title
        self.provider = provider
        self.providerName = providerName
        self.issuer = issuer
        self.accountName = accountName
        self.loginURL = loginURL
        self.linkedLoginEntryID = linkedLoginEntryID
        self.notes = notes
        self.secret = secret
        self.metadata = metadata
    }
}

public struct LocalSSOEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let provider: SSOProvider
    public let providerName: String
    public let issuer: String
    public let accountName: String
    public let loginURL: String
    public let linkedLoginEntryID: String?
    public let notes: String
    public let secret: String
    public let favorite: Bool
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        title: String,
        provider: SSOProvider = .custom,
        providerName: String = "",
        issuer: String = "",
        accountName: String = "",
        loginURL: String = "",
        linkedLoginEntryID: String? = nil,
        notes: String = "",
        secret: String = "",
        favorite: Bool = false,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.provider = provider
        self.providerName = providerName
        self.issuer = issuer
        self.accountName = accountName
        self.loginURL = loginURL
        self.linkedLoginEntryID = linkedLoginEntryID
        self.notes = notes
        self.secret = secret
        self.favorite = favorite
        self.metadata = metadata
    }

    public var displayProviderName: String {
        let trimmed = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.displayName : trimmed
    }

    /// 只有通过校验的地址才会返回，UI 用它决定「打开登录页」是否可点。
    public var sanitizedLoginURL: URL? {
        SSOEntryURLValidator.sanitizedURL(from: loginURL)
    }

    public var sanitizedIssuerURL: URL? {
        SSOEntryURLValidator.isSecureIssuer(issuer) ? SSOEntryURLValidator.sanitizedURL(from: issuer) : nil
    }

    /// 关联登录项已删除时返回 nil，调用方据此展示「关联项已删除」而不是丢数据。
    public func resolvedLinkedLoginEntry(in entries: [LocalLoginEntry]) -> LocalLoginEntry? {
        guard let linkedLoginEntryID, !linkedLoginEntryID.isEmpty else {
            return nil
        }
        return entries.first { $0.id == linkedLoginEntryID }
    }

    public var searchableText: String {
        [title, displayProviderName, accountName, loginURL, issuer, notes]
            .joined(separator: " ")
    }
}

extension LocalVaultEntryRepository {
    public func createSSOEntry(projectID: String, draft: LocalSSOEntryDraft) throws -> LocalSSOEntry {
        try engine.createSSOEntry(in: session.handle, projectID: projectID, draft: normalizedSSOEntryDraft(draft))
    }

    public func listSSOEntries(projectID: String) throws -> [LocalSSOEntry] {
        try engine.listSSOEntries(in: session.handle, projectID: projectID)
    }

    public func updateSSOEntry(projectID: String, entryID: String, draft: LocalSSOEntryDraft) throws -> LocalSSOEntry {
        try engine.updateSSOEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedSSOEntryDraft(draft))
    }

    public func setSSOEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalSSOEntry {
        try engine.setSSOEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteSSOEntry(projectID: String, entryID: String) throws {
        try engine.deleteSSOEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedSSOEntries(projectID: String) throws -> [LocalSSOEntry] {
        try engine.listDeletedSSOEntries(in: session.handle, projectID: projectID)
    }

    public func restoreSSOEntry(projectID: String, entryID: String) throws -> LocalSSOEntry {
        try engine.restoreSSOEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    private func normalizedSSOEntryDraft(_ draft: LocalSSOEntryDraft) throws -> LocalSSOEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        let loginURL = draft.loginURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !loginURL.isEmpty, SSOEntryURLValidator.error(for: loginURL) != nil {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        let issuer = draft.issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !issuer.isEmpty, SSOEntryURLValidator.issuerError(for: issuer) != nil {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        let linkedID = draft.linkedLoginEntryID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalSSOEntryDraft(
            title: normalizedTitle,
            provider: draft.provider,
            providerName: draft.providerName.trimmingCharacters(in: .whitespacesAndNewlines),
            issuer: issuer,
            accountName: draft.accountName.trimmingCharacters(in: .whitespacesAndNewlines),
            loginURL: loginURL,
            linkedLoginEntryID: (linkedID?.isEmpty ?? true) ? nil : linkedID,
            notes: draft.notes,
            secret: draft.secret
        )
    }
}

extension MDBXLocalVaultEngine {
    public func createSSOEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSSOEntryDraft) throws -> LocalSSOEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "sso",
            title: draft.title,
            payload: Self.ssoPayload(for: draft)
        )
        return try LocalSSOEntry(entry)
    }

    public func listSSOEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSSOEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "sso").map(LocalSSOEntry.init)
    }

    public func updateSSOEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSSOEntryDraft) throws -> LocalSSOEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "sso",
            title: draft.title,
            payload: Self.ssoPayload(for: draft)
        )
        return try LocalSSOEntry(entry)
    }

    public func setSSOEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSSOEntry {
        try LocalSSOEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "sso", favorite: favorite))
    }

    public func deleteSSOEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "sso")
    }

    public func listDeletedSSOEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSSOEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "sso").map(LocalSSOEntry.init)
    }

    public func restoreSSOEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSSOEntry {
        try LocalSSOEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "sso"))
    }

    /// SSO 条目的加密载荷：secret 与备注同其它 parity 条目一样落在加密后的 payload 中，
    /// 不会写入 UserDefaults、日志或任何明文索引。
    private static func ssoPayload(for draft: LocalSSOEntryDraft) -> [String: Any] {
        [
            "provider": draft.provider.rawValue,
            "providerName": draft.providerName,
            "issuer": draft.issuer,
            "accountName": draft.accountName,
            "loginURL": draft.loginURL,
            "linkedLoginEntryID": draft.linkedLoginEntryID ?? "",
            "notes": draft.notes,
            "secret": draft.secret
        ]
    }
}

private extension LocalSSOEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        let linkedID = payload.string("linkedLoginEntryID")
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            provider: SSOProvider.fromStoredValue(payload.string("provider")),
            providerName: payload.string("providerName"),
            issuer: payload.string("issuer"),
            accountName: payload.string("accountName"),
            loginURL: payload.string("loginURL"),
            linkedLoginEntryID: linkedID.isEmpty ? nil : linkedID,
            notes: payload.string("notes"),
            secret: payload.string("secret"),
            favorite: entry.favorite,
            metadata: VaultEntryMetadata(entry.metadata)
        )
    }
}
