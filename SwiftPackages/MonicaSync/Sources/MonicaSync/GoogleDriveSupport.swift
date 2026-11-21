//
//  GoogleDriveSupport.swift
//  MonicaSync
//
//  Google Drive OAuth 2.0 (PKCE) and REST v3 support for KeePass `.kdbx` files.
//
//  Configuration is never guessed: the client ID and redirect URL scheme come
//  from the app bundle (`GoogleDriveClientID` in Info.plist and the matching
//  `CFBundleURLTypes` entry). When they are missing the provider reports
//  "未配置" and the UI disables it, leaving OneDrive / WebDAV untouched.
//
//  Tokens are stored in the Keychain with
//  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; they are never written to
//  UserDefaults, printed, or embedded in error messages.
//

import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

// MARK: - SHA256

/// SHA-256 helper shared by the cloud browser receipts. `CryptoKit` keeps this
/// dependency-free on iOS 17 / macOS 13.
public enum CloudFileSHA256 {
    public static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }
}

// MARK: - Configuration

public struct GoogleDriveConfiguration: Sendable, Equatable {
    /// OAuth client ID of type "iOS" from Google Cloud Console.
    public let clientID: String
    /// Reversed-client-ID URL scheme registered in `CFBundleURLTypes`, e.g.
    /// `com.googleusercontent.apps.1234-abc`.
    public let redirectScheme: String
    /// Least-privilege scope: only files this app created or the user opened
    /// with it.
    public let scopes: [String]
    public let apiBaseURL: URL
    public let uploadBaseURL: URL
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let revocationEndpoint: URL
    public let maximumPageSize: Int

    public init(
        clientID: String = "",
        redirectScheme: String = "",
        scopes: [String] = ["https://www.googleapis.com/auth/drive.file"],
        apiBaseURL: URL = URL(string: "https://www.googleapis.com/drive/v3")!,
        uploadBaseURL: URL = URL(string: "https://www.googleapis.com/upload/drive/v3")!,
        authorizationEndpoint: URL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!,
        revocationEndpoint: URL = URL(string: "https://oauth2.googleapis.com/revoke")!,
        maximumPageSize: Int = 1000
    ) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.redirectScheme = redirectScheme.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scopes = scopes
        self.apiBaseURL = apiBaseURL
        self.uploadBaseURL = uploadBaseURL
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.maximumPageSize = max(1, maximumPageSize)
    }

    /// A Google "iOS" OAuth client uses `<scheme>:/oauth2redirect` as its
    /// redirect URI. The scheme is configuration input, not a guess.
    public var redirectURI: String {
        "\(redirectScheme):/oauth2redirect"
    }

    public var isConfigured: Bool {
        !clientID.isEmpty && !redirectScheme.isEmpty
    }

    public var notConfiguredReason: String {
        "Google Drive 未配置：请在 Info.plist 中设置 GoogleDriveClientID 与对应的 URL scheme。"
    }

    /// Reads the app bundle. Both keys are optional so an unconfigured build
    /// still launches and keeps the other providers available.
    public static func fromBundle(_ bundle: Bundle = .main) -> GoogleDriveConfiguration {
        let clientID = bundle.object(forInfoDictionaryKey: "GoogleDriveClientID") as? String ?? ""
        let redirectScheme = googleRedirectScheme(in: bundle) ?? ""
        return GoogleDriveConfiguration(clientID: clientID, redirectScheme: redirectScheme)
    }

    private static func googleRedirectScheme(in bundle: Bundle) -> String? {
        guard let urlTypes = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            return nil
        }
        for urlType in urlTypes {
            guard let schemeName = urlType["CFBundleURLName"] as? String,
                  schemeName.localizedCaseInsensitiveContains("google")
            else {
                continue
            }
            if let schemes = urlType["CFBundleURLSchemes"] as? [String],
               let scheme = schemes.first(where: { $0.hasPrefix("com.googleusercontent.apps.") }) {
                return scheme
            }
        }
        // Fallback for builds that only register the reversed client ID.
        for urlType in urlTypes {
            if let schemes = urlType["CFBundleURLSchemes"] as? [String],
               let scheme = schemes.first(where: { $0.hasPrefix("com.googleusercontent.apps.") }) {
                return scheme
            }
        }
        return nil
    }
}

// MARK: - PKCE

public struct GoogleDrivePKCE: Sendable, Equatable {
    public static let method = "S256"
    public static let minimumVerifierLength = 43
    public static let maximumVerifierLength = 128

    public let codeVerifier: String
    public let codeChallenge: String

    public init(codeVerifier: String) throws {
        let length = codeVerifier.count
        guard length >= Self.minimumVerifierLength, length <= Self.maximumVerifierLength else {
            throw GoogleDriveAuthError.invalidCodeVerifier
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard codeVerifier.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw GoogleDriveAuthError.invalidCodeVerifier
        }
        self.init(validatedVerifier: codeVerifier)
    }

    /// Internal path for verifiers this type generated itself.
    private init(validatedVerifier: String) {
        self.codeVerifier = validatedVerifier
        self.codeChallenge = Self.challenge(for: validatedVerifier)
    }

    /// RFC 7636 S256: `BASE64URL(SHA256(ASCII(code_verifier)))` without padding.
    public static func challenge(for codeVerifier: String) -> String {
        let digest = SHA256.hash(data: Data(codeVerifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func generate() -> GoogleDrivePKCE {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let verifier = String((0..<64).map { _ in alphabet.randomElement()! })
        return GoogleDrivePKCE(validatedVerifier: verifier)
    }

    func authorizationQueryItems(state: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: Self.method),
            URLQueryItem(name: "state", value: state)
        ]
    }
}

// MARK: - Token model

public struct GoogleDriveOAuthToken: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let scope: String?
    public let tokenType: String

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date,
        scope: String? = nil,
        tokenType: String = "Bearer"
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
    }

    public func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }

    public var redactedDescription: String {
        "GoogleDrive token expires at \(Int(expiresAt.timeIntervalSince1970))"
    }
}

extension GoogleDriveOAuthToken: Codable {
    private enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case expiresAt
        case scope
        case tokenType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        let interval = try container.decode(Double.self, forKey: .expiresAt)
        expiresAt = Date(timeIntervalSince1970: interval)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType) ?? "Bearer"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try container.encode(expiresAt.timeIntervalSince1970, forKey: .expiresAt)
        try container.encodeIfPresent(scope, forKey: .scope)
        try container.encode(tokenType, forKey: .tokenType)
    }
}

public enum GoogleDriveAuthError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured
    case invalidCodeVerifier
    case invalidAuthorizationURL
    case authorizationCancelled
    case authorizationDenied
    case invalidCallback
    case stateMismatch
    case missingAuthorizationCode
    case tokenExchangeFailed(statusCode: Int)
    case refreshFailed(statusCode: Int)
    case refreshTokenRevoked
    case missingRefreshToken
    case keychainFailure(status: Int32)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google Drive 未配置：请在 Info.plist 中设置 GoogleDriveClientID 与对应的 URL scheme。"
        case .invalidCodeVerifier:
            return "Google Drive 登录参数无效，请重试。"
        case .invalidAuthorizationURL:
            return "无法生成 Google Drive 登录地址。"
        case .authorizationCancelled:
            return "已取消 Google Drive 登录。"
        case .authorizationDenied:
            return "Google Drive 授权被拒绝，未授予访问权限。"
        case .invalidCallback:
            return "Google Drive 登录回调无效，请重试。"
        case .stateMismatch:
            return "Google Drive 登录状态校验失败，请重试。"
        case .missingAuthorizationCode:
            return "Google Drive 登录未返回授权码，请重试。"
        case .tokenExchangeFailed(let statusCode):
            return "Google Drive 令牌交换失败（HTTP \(statusCode)）。"
        case .refreshFailed(let statusCode):
            return "Google Drive 登录已过期，刷新失败（HTTP \(statusCode)）。"
        case .refreshTokenRevoked:
            return "Google Drive 授权已撤销，请重新登录。"
        case .missingRefreshToken:
            return "Google Drive 登录已过期，请重新登录。"
        case .keychainFailure(let status):
            return "无法安全保存 Google Drive 登录信息（Keychain \(status)）。"
        }
    }
}

// MARK: - Token store

public protocol GoogleDriveTokenStore: Sendable {
    func loadToken() throws -> GoogleDriveOAuthToken?
    func saveToken(_ token: GoogleDriveOAuthToken) throws
    func clearToken() throws
}

/// Test / preview store. Production uses `KeychainGoogleDriveTokenStore`.
public final class InMemoryGoogleDriveTokenStore: GoogleDriveTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: GoogleDriveOAuthToken?

    public init(token: GoogleDriveOAuthToken? = nil) {
        self.token = token
    }

    public func loadToken() throws -> GoogleDriveOAuthToken? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    public func saveToken(_ token: GoogleDriveOAuthToken) throws {
        lock.lock()
        defer { lock.unlock() }
        self.token = token
    }

    public func clearToken() throws {
        lock.lock()
        defer { lock.unlock() }
        token = nil
    }
}

#if canImport(Security)
/// Keychain-backed token store. Items are device-only and only readable while
/// the device is unlocked; they are not synchronized or backed up.
public final class KeychainGoogleDriveTokenStore: GoogleDriveTokenStore, @unchecked Sendable {
    public static let defaultService = "com.monicapass.monica.googledrive.oauth"
    public static let defaultAccount = "oauth-token"

    private let service: String
    private let account: String

    public init(service: String = KeychainGoogleDriveTokenStore.defaultService, account: String = KeychainGoogleDriveTokenStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    public func loadToken() throws -> GoogleDriveOAuthToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                return nil
            }
            return try JSONDecoder().decode(GoogleDriveOAuthToken.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw GoogleDriveAuthError.keychainFailure(status: status)
        }
    }

    public func saveToken(_ token: GoogleDriveOAuthToken) throws {
        let data = try JSONEncoder().encode(token)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw GoogleDriveAuthError.keychainFailure(status: updateStatus)
        }
        var addQuery = baseQuery
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GoogleDriveAuthError.keychainFailure(status: addStatus)
        }
    }

    public func clearToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleDriveAuthError.keychainFailure(status: status)
        }
    }
}
#endif

// MARK: - HTTP transport

public struct GoogleDriveHTTPRequest: Sendable, Equatable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    public func headerValue(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct GoogleDriveHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func headerValue(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var bodyString: String {
        String(data: body, encoding: .utf8) ?? ""
    }
}

public protocol GoogleDriveHTTPTransport: Sendable {
    func send(_ request: GoogleDriveHTTPRequest) async throws -> GoogleDriveHTTPResponse
}

public struct URLSessionGoogleDriveHTTPTransport: GoogleDriveHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: GoogleDriveHTTPRequest) async throws -> GoogleDriveHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return GoogleDriveHTTPResponse(statusCode: httpResponse.statusCode, headers: headers, body: data)
    }
}

// MARK: - Authorization presenting

/// Presents the OAuth consent page. The app implements this with
/// `ASWebAuthenticationSession`; tests inject a stub so no real network or UI is
/// involved.
public protocol GoogleDriveAuthorizationPresenting: Sendable {
    func presentAuthorization(url: URL, callbackURLScheme: String) async throws -> URL
}

// MARK: - Access token providing

public protocol GoogleDriveAccessTokenProvider: Sendable {
    func accessToken() async throws -> String
    /// Forces a refresh and returns the new token. Used after a 401.
    func refreshAccessToken() async throws -> String
}

public struct EmptyGoogleDriveAccessTokenProvider: GoogleDriveAccessTokenProvider {
    public init() {}

    public func accessToken() async throws -> String {
        throw CloudFileProviderError.authenticationRequired(provider: .googleDrive)
    }

    public func refreshAccessToken() async throws -> String {
        throw CloudFileProviderError.authenticationRequired(provider: .googleDrive)
    }
}

// MARK: - OAuth service

/// Owns the PKCE dance, token refresh and revocation. All network calls go
/// through the injected `GoogleDriveHTTPTransport`.
public final class GoogleDriveOAuthService: GoogleDriveAccessTokenProvider, @unchecked Sendable {
    public let configuration: GoogleDriveConfiguration

    private let tokenStore: any GoogleDriveTokenStore
    private let transport: any GoogleDriveHTTPTransport
    private let presenter: any GoogleDriveAuthorizationPresenting
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    public init(
        configuration: GoogleDriveConfiguration,
        tokenStore: any GoogleDriveTokenStore,
        transport: any GoogleDriveHTTPTransport = URLSessionGoogleDriveHTTPTransport(),
        presenter: any GoogleDriveAuthorizationPresenting,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.transport = transport
        self.presenter = presenter
        self.now = now
    }

    public var availability: CloudFileBrowserAvailability {
        configuration.isConfigured ? .available : .notConfigured(reason: configuration.notConfiguredReason)
    }

    public func connectionState() async throws -> CloudFileConnectionState {
        do {
            _ = try await accessToken()
            return .connected(accountLabel: "Google Drive")
        } catch let error as CloudFileProviderError {
            if case .authenticationRequired = error {
                return .disconnected
            }
            throw error
        }
    }

    @discardableResult
    public func signIn() async throws -> GoogleDriveOAuthToken {
        guard configuration.isConfigured else {
            throw GoogleDriveAuthError.notConfigured
        }
        let pkce = GoogleDrivePKCE.generate()
        let state = Self.randomState()
        guard let authorizationURL = authorizationURL(pkce: pkce, state: state) else {
            throw GoogleDriveAuthError.invalidAuthorizationURL
        }

        let callbackURL = try await presenter.presentAuthorization(
            url: authorizationURL,
            callbackURLScheme: configuration.redirectScheme
        )
        let code = try authorizationCode(from: callbackURL, expectedState: state)
        let token = try await exchangeAuthorizationCode(code, pkce: pkce)
        try tokenStore.saveToken(token)
        return token
    }

    public func signOut() async throws {
        let token = try? tokenStore.loadToken()
        try tokenStore.clearToken()
        guard let refreshToken = token?.refreshToken ?? token?.accessToken else {
            return
        }
        // Best effort revocation; a revoked token simply requires sign-in again.
        var components = URLComponents(url: configuration.revocationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: refreshToken)]
        guard let url = components?.url else {
            return
        }
        _ = try? await transport.send(
            GoogleDriveHTTPRequest(method: "POST", url: url, headers: ["Content-Type": "application/x-www-form-urlencoded"])
        )
    }

    public func accessToken() async throws -> String {
        let token = try tokenStore.loadToken()
        guard let token else {
            throw CloudFileProviderError.authenticationRequired(provider: .googleDrive)
        }
        if !token.isExpired(now: now()) {
            return token.accessToken
        }
        return try await refreshAccessToken()
    }

    public func refreshAccessToken() async throws -> String {
        let stored = try tokenStore.loadToken()
        guard let refreshToken = stored?.refreshToken, !refreshToken.isEmpty else {
            try? tokenStore.clearToken()
            throw CloudFileProviderError.authenticationRequired(provider: .googleDrive)
        }
        let response = try await transport.send(
            GoogleDriveHTTPRequest(
                method: "POST",
                url: configuration.tokenEndpoint,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: Self.formEncoded([
                    "client_id": configuration.clientID,
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken
                ])
            )
        )
        guard response.statusCode == 200 else {
            if response.statusCode == 400 || response.statusCode == 401 {
                try? tokenStore.clearToken()
                throw CloudFileProviderError.authenticationRequired(provider: .googleDrive)
            }
            throw GoogleDriveAuthError.refreshFailed(statusCode: response.statusCode)
        }
        let payload = try JSONDecoder().decode(TokenEndpointResponse.self, from: response.body)
        let token = GoogleDriveOAuthToken(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken ?? refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(payload.expiresIn ?? 3600)),
            scope: payload.scope,
            tokenType: payload.tokenType ?? "Bearer"
        )
        try tokenStore.saveToken(token)
        return token.accessToken
    }

    /// Handles a redirect delivered by the app (`onOpenURL`). Returns `true` when
    /// the URL belongs to the Google Drive flow.
    public func handleRedirectURL(_ url: URL) -> Bool {
        url.scheme?.caseInsensitiveCompare(configuration.redirectScheme) == .orderedSame
    }

    // MARK: URL building

    func authorizationURL(pkce: GoogleDrivePKCE, state: String) -> URL? {
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        items.append(contentsOf: pkce.authorizationQueryItems(state: state))
        components?.queryItems = items
        return components?.url
    }

    func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw GoogleDriveAuthError.invalidCallback
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if let error = value("error") {
            if error == "access_denied" {
                throw GoogleDriveAuthError.authorizationDenied
            }
            throw GoogleDriveAuthError.invalidCallback
        }
        guard let state = value("state"), state == expectedState else {
            throw GoogleDriveAuthError.stateMismatch
        }
        guard let code = value("code"), !code.isEmpty else {
            throw GoogleDriveAuthError.missingAuthorizationCode
        }
        return code
    }

    private func exchangeAuthorizationCode(_ code: String, pkce: GoogleDrivePKCE) async throws -> GoogleDriveOAuthToken {
        let response = try await transport.send(
            GoogleDriveHTTPRequest(
                method: "POST",
                url: configuration.tokenEndpoint,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: Self.formEncoded([
                    "client_id": configuration.clientID,
                    "code": code,
                    "code_verifier": pkce.codeVerifier,
                    "grant_type": "authorization_code",
                    "redirect_uri": configuration.redirectURI
                ])
            )
        )
        guard response.statusCode == 200 else {
            throw GoogleDriveAuthError.tokenExchangeFailed(statusCode: response.statusCode)
        }
        let payload = try JSONDecoder().decode(TokenEndpointResponse.self, from: response.body)
        return GoogleDriveOAuthToken(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(payload.expiresIn ?? 3600)),
            scope: payload.scope,
            tokenType: payload.tokenType ?? "Bearer"
        )
    }

    // MARK: Helpers

    private struct TokenEndpointResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?
        let scope: String?
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
            case tokenType = "token_type"
        }
    }

    static func formEncoded(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = values
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private static func randomState() -> String {
        // Swift's system RNG is cryptographically secure on Apple platforms; the
        // value only needs to be unguessable for the OAuth state echo.
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
