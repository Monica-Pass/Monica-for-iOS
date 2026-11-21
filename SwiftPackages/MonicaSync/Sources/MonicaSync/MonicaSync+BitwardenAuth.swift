// MARK: - Bitwarden 认证与会话（登录 / 两步验证 / 会话与密钥存储）

import Foundation

public struct BitwardenAuthenticationSession: Sendable, Equatable, Codable {
    public let accountLabel: String
    public let serverURL: URL
    public let identityURL: URL
    public let apiURL: URL
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date

    public init(
        accountLabel: String,
        serverURL: URL,
        identityURL: URL,
        apiURL: URL,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date
    ) {
        self.accountLabel = accountLabel
        self.serverURL = serverURL
        self.identityURL = identityURL
        self.apiURL = apiURL
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public func isAccessTokenExpired(now: Date = Date(), tolerance: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) <= tolerance
    }

    public func refreshed(
        accessToken: String,
        refreshToken: String?,
        expiresIn: TimeInterval,
        now: Date = Date()
    ) -> BitwardenAuthenticationSession {
        BitwardenAuthenticationSession(
            accountLabel: accountLabel,
            serverURL: serverURL,
            identityURL: identityURL,
            apiURL: apiURL,
            accessToken: accessToken,
            refreshToken: refreshToken ?? self.refreshToken,
            expiresAt: now.addingTimeInterval(expiresIn)
        )
    }

    public var redactedSummary: String {
        let normalized = sanitizedBitwardenText(accountLabel)
        return normalized.isEmpty ? "Bitwarden 已登录" : "Bitwarden \(normalized) 已登录"
    }
}

public protocol BitwardenAuthenticationSessionStore: Sendable {
    func loadSession() throws -> BitwardenAuthenticationSession?
    func saveSession(_ session: BitwardenAuthenticationSession) throws
    func clearSession() throws
}

public final class MemoryBitwardenAuthenticationSessionStore: BitwardenAuthenticationSessionStore, @unchecked Sendable {
    private var session: BitwardenAuthenticationSession?

    public init(session: BitwardenAuthenticationSession? = nil) {
        self.session = session
    }

    public func loadSession() throws -> BitwardenAuthenticationSession? {
        session
    }

    public func saveSession(_ session: BitwardenAuthenticationSession) throws {
        self.session = session
    }

    public func clearSession() throws {
        session = nil
    }
}

public struct BitwardenVaultKey: Sendable, Equatable, Codable {
    public let encryptionKey: Data
    public let macKey: Data

    public init(encryptionKey: Data, macKey: Data) {
        self.encryptionKey = encryptionKey
        self.macKey = macKey
    }

    public var redactedSummary: String {
        "Bitwarden vault key 已解锁"
    }
}

public protocol BitwardenVaultKeyStore: Sendable {
    func loadVaultKey(accountLabel: String) throws -> BitwardenVaultKey?
    func saveVaultKey(_ key: BitwardenVaultKey, accountLabel: String) throws
    func clearVaultKey(accountLabel: String?) throws
}

public final class MemoryBitwardenVaultKeyStore: BitwardenVaultKeyStore, @unchecked Sendable {
    private var keysByAccountLabel: [String: BitwardenVaultKey] = [:]

    public init() {}

    public func loadVaultKey(accountLabel: String) throws -> BitwardenVaultKey? {
        keysByAccountLabel[normalizedBitwardenAccountLabel(accountLabel)]
    }

    public func saveVaultKey(_ key: BitwardenVaultKey, accountLabel: String) throws {
        keysByAccountLabel[normalizedBitwardenAccountLabel(accountLabel)] = key
    }

    public func clearVaultKey(accountLabel: String?) throws {
        guard let accountLabel else {
            keysByAccountLabel.removeAll()
            return
        }
        keysByAccountLabel.removeValue(forKey: normalizedBitwardenAccountLabel(accountLabel))
    }
}

public enum BitwardenKDF: Int, Sendable, Equatable, Codable {
    case pbkdf2 = 0
    case argon2id = 1
}

public struct BitwardenPreloginResult: Sendable, Equatable {
    public let kdf: BitwardenKDF
    public let iterations: Int
    public let memory: Int?
    public let parallelism: Int?

    public init(kdf: BitwardenKDF, iterations: Int, memory: Int? = nil, parallelism: Int? = nil) {
        self.kdf = kdf
        self.iterations = iterations
        self.memory = memory
        self.parallelism = parallelism
    }
}

public struct BitwardenPreloginHTTPRequest: Sendable, Equatable {
    public let url: URL
    public let email: String
}

public struct BitwardenTokenHTTPRequest: Sendable, Equatable {
    public let url: URL
    public let headers: [String: String]
    public let form: [String: String]
}

public struct BitwardenTwoFactorEmailLoginHTTPRequest: Sendable, Equatable {
    public let url: URL
    public let email: String
    public let masterPasswordHash: String
}

public struct BitwardenTwoFactorProvider: Sendable, Equatable, Codable, Identifiable {
    public var id: Int { providerID }

    public let providerID: Int
    public let displayName: String

    public init(providerID: Int, displayName: String? = nil) {
        self.providerID = providerID
        self.displayName = displayName ?? Self.defaultDisplayName(for: providerID)
    }

    private static func defaultDisplayName(for providerID: Int) -> String {
        switch providerID {
        case 0:
            "Authenticator App"
        case 1:
            "Email"
        case 2:
            "Duo"
        case 3:
            "YubiKey"
        case 4:
            "U2F"
        case 5:
            "Remembered Device"
        case 6:
            "Organization Duo"
        case 7:
            "WebAuthn"
        case -100:
            "Email New Device"
        default:
            "Unknown"
        }
    }
}

public struct BitwardenTwoFactorLoginChallenge: Sendable, Equatable {
    public let accountLabel: String
    public let serverURL: URL
    public let identityURL: URL
    public let apiURL: URL
    public let providers: [BitwardenTwoFactorProvider]
    public let kdf: BitwardenKDF
    public let kdfIterations: Int
    public let kdfMemory: Int?
    public let kdfParallelism: Int?
    let passwordHash: String
    let stretchedKey: BitwardenVaultKey
    let deviceIdentifier: String

    public init(
        accountLabel: String,
        serverURL: URL,
        identityURL: URL,
        apiURL: URL,
        providers: [BitwardenTwoFactorProvider],
        kdf: BitwardenKDF,
        kdfIterations: Int,
        kdfMemory: Int?,
        kdfParallelism: Int?,
        passwordHash: String,
        stretchedKey: BitwardenVaultKey,
        deviceIdentifier: String
    ) {
        self.accountLabel = accountLabel
        self.serverURL = serverURL
        self.identityURL = identityURL
        self.apiURL = apiURL
        self.providers = providers
        self.kdf = kdf
        self.kdfIterations = kdfIterations
        self.kdfMemory = kdfMemory
        self.kdfParallelism = kdfParallelism
        self.passwordHash = passwordHash
        self.stretchedKey = stretchedKey
        self.deviceIdentifier = deviceIdentifier
    }

    public var supportsEmailCodeRequest: Bool {
        providers.contains { $0.providerID == 1 }
    }

    public var redactedSummary: String {
        let providerSummary = providers.map(\.displayName).joined(separator: "、")
        let normalized = sanitizedBitwardenText(accountLabel)
        return providerSummary.isEmpty
            ? "Bitwarden \(normalized) 需要两步验证"
            : "Bitwarden \(normalized) 需要两步验证：\(providerSummary)"
    }
}

public enum BitwardenPasswordAuthenticationResult: Sendable, Equatable {
    case authenticated(BitwardenAuthenticationSession)
    case twoFactorRequired(BitwardenTwoFactorLoginChallenge)
}

public struct BitwardenPasswordAuthenticationHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol BitwardenPasswordAuthenticationTransport: Sendable {
    func prelogin(_ request: BitwardenPreloginHTTPRequest) async throws -> BitwardenPasswordAuthenticationHTTPResponse
    func token(_ request: BitwardenTokenHTTPRequest) async throws -> BitwardenPasswordAuthenticationHTTPResponse
    func sendEmailTwoFactor(_ request: BitwardenTwoFactorEmailLoginHTTPRequest) async throws -> BitwardenPasswordAuthenticationHTTPResponse
}

public extension BitwardenPasswordAuthenticationTransport {
    func sendEmailTwoFactor(
        _ request: BitwardenTwoFactorEmailLoginHTTPRequest
    ) async throws -> BitwardenPasswordAuthenticationHTTPResponse {
        throw BitwardenSyncProviderError.unsupportedOperation
    }
}

public struct BitwardenPasswordAuthenticator: Sendable {
    private let sessionStore: any BitwardenAuthenticationSessionStore
    private let vaultKeyStore: any BitwardenVaultKeyStore
    private let transport: any BitwardenPasswordAuthenticationTransport
    private let deviceIdentifier: @Sendable () -> String
    private let now: @Sendable () -> Date

    public init(
        sessionStore: any BitwardenAuthenticationSessionStore,
        vaultKeyStore: any BitwardenVaultKeyStore,
        transport: any BitwardenPasswordAuthenticationTransport = URLSessionBitwardenPasswordAuthenticationTransport(),
        deviceIdentifier: @escaping @Sendable () -> String = { UUID().uuidString },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sessionStore = sessionStore
        self.vaultKeyStore = vaultKeyStore
        self.transport = transport
        self.deviceIdentifier = deviceIdentifier
        self.now = now
    }

    public func signIn(
        email: String,
        masterPassword: String,
        serverURL: URL = URL(string: "https://vault.bitwarden.com")!
    ) async throws -> BitwardenAuthenticationSession {
        switch try await beginSignIn(email: email, masterPassword: masterPassword, serverURL: serverURL) {
        case .authenticated(let session):
            return session
        case .twoFactorRequired:
            throw BitwardenSyncProviderError.twoFactorRequired
        }
    }

    public func beginSignIn(
        email: String,
        masterPassword: String,
        serverURL: URL = URL(string: "https://vault.bitwarden.com")!
    ) async throws -> BitwardenPasswordAuthenticationResult {
        guard Self.isValidServerURL(serverURL) else {
            throw BitwardenSyncProviderError.invalidServerURL
        }
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        guard !masterPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        let urls = BitwardenServerURLs(serverURL: serverURL)
        let preloginResponse = try await transport.prelogin(
            BitwardenPreloginHTTPRequest(
                url: Self.preloginURL(identityURL: urls.identityURL),
                email: normalizedEmail
            )
        )
        guard (200...299).contains(preloginResponse.statusCode) else {
            throw BitwardenSyncProviderError.serverRejected(statusCode: preloginResponse.statusCode)
        }
        let prelogin = try BitwardenPreloginPayload.decode(preloginResponse.body)
        let masterKey: Data
        switch prelogin.kdf {
        case .pbkdf2:
            masterKey = try BitwardenCrypto.deriveMasterKeyPBKDF2(
                password: masterPassword,
                salt: normalizedEmail.lowercased(),
                iterations: prelogin.iterations
            )
        case .argon2id:
            masterKey = try BitwardenCrypto.deriveMasterKeyArgon2id(
                password: masterPassword,
                salt: normalizedEmail.lowercased(),
                iterations: prelogin.iterations,
                memory: prelogin.memory ?? 64,
                parallelism: prelogin.parallelism ?? 4
            )
        }
        let passwordHash = try BitwardenCrypto.deriveMasterPasswordHash(
            masterKey: masterKey,
            password: masterPassword
        )
        let stretchedKey = try BitwardenCrypto.stretchMasterKey(masterKey)
        let currentDeviceIdentifier = deviceIdentifier()
        let tokenResponse = try await transport.token(
            Self.passwordTokenRequest(
                identityURL: urls.identityURL,
                email: normalizedEmail,
                passwordHash: passwordHash,
                deviceIdentifier: currentDeviceIdentifier
            )
        )
        guard (200...299).contains(tokenResponse.statusCode) else {
            if BitwardenTokenPayload.containsTwoFactorChallenge(tokenResponse.body) {
                return .twoFactorRequired(
                    BitwardenTwoFactorLoginChallenge(
                        accountLabel: normalizedEmail,
                        serverURL: urls.serverURL,
                        identityURL: urls.identityURL,
                        apiURL: urls.apiURL,
                        providers: BitwardenTokenPayload.twoFactorProviders(from: tokenResponse.body),
                        kdf: prelogin.kdf,
                        kdfIterations: prelogin.iterations,
                        kdfMemory: prelogin.memory,
                        kdfParallelism: prelogin.parallelism,
                        passwordHash: passwordHash,
                        stretchedKey: stretchedKey,
                        deviceIdentifier: currentDeviceIdentifier
                    )
                )
            }
            throw BitwardenSyncProviderError.authenticationRequired
        }
        let payload = try BitwardenTokenPayload.decode(tokenResponse.body)
        guard let encryptedKey = payload.key, !encryptedKey.isEmpty else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        let vaultKey = try BitwardenCrypto.decryptSymmetricKey(encryptedKey, key: stretchedKey)
        let session = BitwardenAuthenticationSession(
            accountLabel: normalizedEmail,
            serverURL: urls.serverURL,
            identityURL: urls.identityURL,
            apiURL: urls.apiURL,
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: now().addingTimeInterval(payload.expiresIn)
        )
        try sessionStore.saveSession(session)
        try vaultKeyStore.saveVaultKey(vaultKey, accountLabel: normalizedEmail)
        return .authenticated(session)
    }

    public func completeTwoFactorSignIn(
        _ challenge: BitwardenTwoFactorLoginChallenge,
        code: String,
        providerID: Int,
        rememberDevice: Bool = false
    ) async throws -> BitwardenAuthenticationSession {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCode.isEmpty else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        let request = Self.passwordTokenRequest(
            identityURL: challenge.identityURL,
            email: challenge.accountLabel,
            passwordHash: challenge.passwordHash,
            deviceIdentifier: challenge.deviceIdentifier,
            extraForm: [
                "twoFactorToken": normalizedCode,
                "twoFactorProvider": String(providerID),
                "twoFactorRemember": rememberDevice ? "1" : "0"
            ]
        )
        let tokenResponse = try await transport.token(request)
        guard (200...299).contains(tokenResponse.statusCode) else {
            throw BitwardenTokenPayload.containsTwoFactorChallenge(tokenResponse.body)
                ? BitwardenSyncProviderError.twoFactorRequired
                : BitwardenSyncProviderError.authenticationRequired
        }
        let payload = try BitwardenTokenPayload.decode(tokenResponse.body)
        guard let encryptedKey = payload.key, !encryptedKey.isEmpty else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        let vaultKey = try BitwardenCrypto.decryptSymmetricKey(encryptedKey, key: challenge.stretchedKey)
        let session = BitwardenAuthenticationSession(
            accountLabel: challenge.accountLabel,
            serverURL: challenge.serverURL,
            identityURL: challenge.identityURL,
            apiURL: challenge.apiURL,
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: now().addingTimeInterval(payload.expiresIn)
        )
        try sessionStore.saveSession(session)
        try vaultKeyStore.saveVaultKey(vaultKey, accountLabel: challenge.accountLabel)
        return session
    }

    public func requestEmailTwoFactorCode(for challenge: BitwardenTwoFactorLoginChallenge) async throws {
        guard challenge.supportsEmailCodeRequest else {
            throw BitwardenSyncProviderError.unsupportedOperation
        }
        let response = try await transport.sendEmailTwoFactor(
            BitwardenTwoFactorEmailLoginHTTPRequest(
                url: Self.emailTwoFactorURL(apiURL: challenge.apiURL),
                email: challenge.accountLabel,
                masterPasswordHash: challenge.passwordHash
            )
        )
        guard (200...299).contains(response.statusCode) else {
            throw BitwardenSyncProviderError.serverRejected(statusCode: response.statusCode)
        }
    }

    private static func preloginURL(identityURL: URL) -> URL {
        identityURL.appendingBitwardenPath("accounts/prelogin")
    }

    private static func tokenURL(identityURL: URL) -> URL {
        identityURL.appendingBitwardenPath("connect/token")
    }

    private static func emailTwoFactorURL(apiURL: URL) -> URL {
        apiURL.appendingBitwardenPath("two-factor/send-email-login")
    }

    private static func passwordTokenRequest(
        identityURL: URL,
        email: String,
        passwordHash: String,
        deviceIdentifier: String,
        extraForm: [String: String] = [:]
    ) -> BitwardenTokenHTTPRequest {
        var form: [String: String] = [
            "grant_type": "password",
            "username": email,
            "password": passwordHash,
            "scope": "api offline_access",
            "client_id": "desktop",
            "deviceIdentifier": deviceIdentifier,
            "deviceType": "8",
            "deviceName": "linux"
        ]
        extraForm.forEach { form[$0.key] = $0.value }
        return BitwardenTokenHTTPRequest(
            url: tokenURL(identityURL: identityURL),
            headers: [
                "Auth-Email": Data(email.utf8).base64URLEncodedString(),
                "device-type": "8",
                "cache-control": "no-store",
                "Bitwarden-Client-Name": "desktop",
                "Bitwarden-Client-Version": "2025.9.1",
                "Content-Type": "application/x-www-form-urlencoded"
            ],
            form: form
        )
    }

    private static func isValidServerURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        return true
    }
}

public final class URLSessionBitwardenPasswordAuthenticationTransport: BitwardenPasswordAuthenticationTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func prelogin(_ request: BitwardenPreloginHTTPRequest) async throws -> BitwardenPasswordAuthenticationHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: ["email": request.email])
        return try await send(urlRequest)
    }

    public func token(_ request: BitwardenTokenHTTPRequest) async throws -> BitwardenPasswordAuthenticationHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        request.headers.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = formURLEncodedBody(request.form.sorted { $0.key < $1.key })
        return try await send(urlRequest)
    }

    public func sendEmailTwoFactor(
        _ request: BitwardenTwoFactorEmailLoginHTTPRequest
    ) async throws -> BitwardenPasswordAuthenticationHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "email": request.email,
                "masterPasswordHash": request.masterPasswordHash
            ],
            options: [.sortedKeys]
        )
        return try await send(urlRequest)
    }

    private func send(_ request: URLRequest) async throws -> BitwardenPasswordAuthenticationHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        return BitwardenPasswordAuthenticationHTTPResponse(statusCode: httpResponse.statusCode, body: data)
    }

    private func formURLEncodedBody(_ pairs: [(String, String)]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
        let encoded = pairs.map { key, value in
            let safeKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let safeValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(safeKey)=\(safeValue)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }
}
