import CommonCrypto
import CryptoKit
import Foundation
import Security
import argon2

public enum MonicaSyncBaseline {
    public static let firstBackupProvider = "WebDAV"
}

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

public enum BitwardenCrypto {
    public static func deriveMasterKeyPBKDF2(password: String, salt: String, iterations: Int) throws -> Data {
        try pbkdf2(seed: Data(password.utf8), salt: Data(salt.utf8), iterations: iterations, length: 32)
    }

    public static func deriveMasterKeyArgon2id(
        password: String,
        salt: String,
        iterations: Int,
        memory: Int,
        parallelism: Int
    ) throws -> Data {
        guard iterations > 0,
              memory > 0,
              parallelism > 0,
              let iterationCost = UInt32(exactly: iterations),
              let memoryMiB = UInt32(exactly: memory),
              let laneCount = UInt32(exactly: parallelism) else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        let memoryCost = memoryMiB.multipliedReportingOverflow(by: 1024)
        guard !memoryCost.overflow else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        var passwordBytes = Data(password.utf8)
        let saltHash = SHA256.hash(data: Data(salt.utf8))
        var saltBytes = Data(saltHash)
        var output = Data(repeating: 0, count: 32)
        let passwordLength = passwordBytes.count
        let saltLength = saltBytes.count
        let outputLength = output.count
        let status = output.withUnsafeMutableBytes { outputBuffer in
            passwordBytes.withUnsafeMutableBytes { passwordBuffer in
                saltBytes.withUnsafeMutableBytes { saltBuffer in
                    argon2_hash(
                        iterationCost,
                        memoryCost.partialValue,
                        laneCount,
                        passwordBuffer.baseAddress,
                        passwordLength,
                        saltBuffer.baseAddress,
                        saltLength,
                        outputBuffer.baseAddress,
                        outputLength,
                        nil,
                        0,
                        Argon2_id,
                        UInt32(argon2.ARGON2_VERSION_13.rawValue)
                    )
                }
            }
        }
        passwordBytes.resetBytes(in: passwordBytes.startIndex..<passwordBytes.endIndex)
        saltBytes.resetBytes(in: saltBytes.startIndex..<saltBytes.endIndex)
        guard status == ARGON2_OK.rawValue else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        return output
    }

    public static func deriveMasterPasswordHash(masterKey: Data, password: String) throws -> String {
        try pbkdf2(seed: masterKey, salt: Data(password.utf8), iterations: 1, length: 32).base64EncodedString()
    }

    public static func stretchMasterKey(_ masterKey: Data) throws -> BitwardenVaultKey {
        BitwardenVaultKey(
            encryptionKey: hkdfExpand(prk: masterKey, info: Data("enc".utf8), length: 32),
            macKey: hkdfExpand(prk: masterKey, info: Data("mac".utf8), length: 32)
        )
    }

    public static func decryptSymmetricKey(_ cipherString: String, key: BitwardenVaultKey) throws -> BitwardenVaultKey {
        let decrypted = try decrypt(cipherString, key: key)
        guard decrypted.count == 64 else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        return BitwardenVaultKey(
            encryptionKey: Data(decrypted.prefix(32)),
            macKey: Data(decrypted.dropFirst(32).prefix(32))
        )
    }

    public static func decryptString(_ cipherString: String, key: BitwardenVaultKey) throws -> String {
        guard let value = String(data: try decrypt(cipherString, key: key), encoding: .utf8) else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        return value
    }

    public static func encryptString(_ value: String, key: BitwardenVaultKey) throws -> String {
        try encrypt(Data(value.utf8), key: key)
    }

    public static func encrypt(_ data: Data, key: BitwardenVaultKey, iv: Data? = nil) throws -> String {
        let iv = try iv ?? secureRandomData(count: kCCBlockSizeAES128)
        let ciphertext = try aes256CBCEncrypt(data, key: key.encryptionKey, iv: iv)
        let mac = Data(HMAC<SHA256>.authenticationCode(
            for: iv + ciphertext,
            using: SymmetricKey(data: key.macKey)
        ))
        return [
            "2",
            [
                iv.base64EncodedString(),
                ciphertext.base64EncodedString(),
                mac.base64EncodedString()
            ].joined(separator: "|")
        ].joined(separator: ".")
    }

    public static func isCipherString(_ value: String?) -> Bool {
        guard let value else { return false }
        return BitwardenCipherString.isCipherString(value)
    }

    public static func decrypt(_ cipherString: String, key: BitwardenVaultKey) throws -> Data {
        let parsed = try BitwardenCipherString.parse(cipherString)
        guard parsed.type == 2 else {
            throw BitwardenSyncProviderError.unsupportedOperation
        }
        let expectedMac = Data(HMAC<SHA256>.authenticationCode(
            for: parsed.iv + parsed.ciphertext,
            using: SymmetricKey(data: key.macKey)
        ))
        guard expectedMac == parsed.mac else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        return try aes256CBCDecrypt(parsed.ciphertext, key: key.encryptionKey, iv: parsed.iv)
    }

    public static func deriveSendKey(_ keyMaterial: Data) throws -> BitwardenVaultKey {
        guard keyMaterial.count == 16 else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        let fullKey = hkdf(
            seed: keyMaterial,
            salt: Data("bitwarden-send".utf8),
            info: Data("send".utf8),
            length: 64
        )
        return BitwardenVaultKey(
            encryptionKey: Data(fullKey.prefix(32)),
            macKey: Data(fullKey.dropFirst(32).prefix(32))
        )
    }

    public static func makeSendKeyMaterial() throws -> Data {
        try secureRandomData(count: 16)
    }

    public static func hashSendPassword(_ password: String, keyMaterial: Data) throws -> String {
        try pbkdf2(seed: Data(password.utf8), salt: keyMaterial, iterations: 100_000, length: 32)
            .base64EncodedString()
    }

    public static func encryptSendFileContent(_ data: Data, key: BitwardenVaultKey) throws -> Data {
        let iv = try secureRandomData(count: kCCBlockSizeAES128)
        let ciphertext = try aes256CBCEncrypt(data, key: key.encryptionKey, iv: iv)
        let mac = Data(HMAC<SHA256>.authenticationCode(
            for: iv + ciphertext,
            using: SymmetricKey(data: key.macKey)
        ))
        var output = Data([2])
        output.append(iv)
        output.append(mac)
        output.append(ciphertext)
        return output
    }

    private static func pbkdf2(seed: Data, salt: Data, iterations: Int, length: Int) throws -> Data {
        guard iterations > 0 else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        var output = Data(repeating: 0, count: length)
        let status = output.withUnsafeMutableBytes { outputBytes in
            seed.withUnsafeBytes { seedBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        seedBytes.bindMemory(to: Int8.self).baseAddress,
                        seed.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        outputBytes.bindMemory(to: UInt8.self).baseAddress,
                        length
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        return output
    }

    private static func hkdf(seed: Data, salt: Data, info: Data, length: Int) -> Data {
        let prk = Data(HMAC<SHA256>.authenticationCode(for: seed, using: SymmetricKey(data: salt)))
        return hkdfExpand(prk: prk, info: info, length: length)
    }

    private static func hkdfExpand(prk: Data, info: Data, length: Int) -> Data {
        var output = Data()
        var previous = Data()
        var counter: UInt8 = 1
        while output.count < length {
            var input = Data()
            input.append(previous)
            input.append(info)
            input.append(counter)
            previous = Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: prk)))
            output.append(previous)
            counter &+= 1
        }
        return Data(output.prefix(length))
    }

    private static func aes256CBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        var output = Data(repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.bindMemory(to: UInt8.self).baseAddress,
                            key.count,
                            ivBytes.bindMemory(to: UInt8.self).baseAddress,
                            cipherBytes.bindMemory(to: UInt8.self).baseAddress,
                            ciphertext.count,
                            outputBytes.bindMemory(to: UInt8.self).baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        return Data(output.prefix(outputLength))
    }

    private static func aes256CBCEncrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        var output = Data(repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            plaintext.withUnsafeBytes { plainBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.bindMemory(to: UInt8.self).baseAddress,
                            key.count,
                            ivBytes.bindMemory(to: UInt8.self).baseAddress,
                            plainBytes.bindMemory(to: UInt8.self).baseAddress,
                            plaintext.count,
                            outputBytes.bindMemory(to: UInt8.self).baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        return Data(output.prefix(outputLength))
    }

    private static func secureRandomData(count: Int) throws -> Data {
        var data = Data(repeating: 0, count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.bindMemory(to: UInt8.self).baseAddress!)
        }
        guard status == errSecSuccess else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        return data
    }
}

public enum BitwardenCipherStringProbe {
    public static func isCipherString(_ value: String?) -> Bool {
        BitwardenCrypto.isCipherString(value)
    }
}

private struct BitwardenCipherString {
    let type: Int
    let iv: Data
    let ciphertext: Data
    let mac: Data

    static func isCipherString(_ value: String) -> Bool {
        (try? parse(value)) != nil
    }

    static func parse(_ value: String) throws -> BitwardenCipherString {
        let parts = value.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let type = Int(parts[0]) else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        let cipherParts = parts[1].split(separator: "|").map(String.init)
        guard cipherParts.count == 3,
              let iv = Data(bitwardenBase64Encoded: cipherParts[0]),
              let ciphertext = Data(bitwardenBase64Encoded: cipherParts[1]),
              let mac = Data(bitwardenBase64Encoded: cipherParts[2]) else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        return BitwardenCipherString(type: type, iv: iv, ciphertext: ciphertext, mac: mac)
    }
}

private struct BitwardenServerURLs {
    let serverURL: URL
    let identityURL: URL
    let apiURL: URL

    init(serverURL: URL) {
        self.serverURL = serverURL
        let host = serverURL.host?.lowercased() ?? ""
        if host.contains("bitwarden.eu") {
            identityURL = URL(string: "https://identity.bitwarden.eu")!
            apiURL = URL(string: "https://api.bitwarden.eu")!
        } else if host.contains("bitwarden.com") {
            identityURL = URL(string: "https://identity.bitwarden.com")!
            apiURL = URL(string: "https://api.bitwarden.com")!
        } else {
            identityURL = serverURL.appendingBitwardenPath("identity")
            apiURL = serverURL.appendingBitwardenPath("api")
        }
    }
}

private struct BitwardenPreloginPayload {
    let kdf: BitwardenKDF
    let iterations: Int
    let memory: Int?
    let parallelism: Int?

    static func decode(_ data: Data) throws -> BitwardenPreloginResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawKDF = jsonInt(root, "kdf", "Kdf"),
              let kdf = BitwardenKDF(rawValue: rawKDF) else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        return BitwardenPreloginResult(
            kdf: kdf,
            iterations: jsonInt(root, "kdfIterations", "KdfIterations") ?? 600_000,
            memory: jsonInt(root, "kdfMemory", "KdfMemory"),
            parallelism: jsonInt(root, "kdfParallelism", "KdfParallelism")
        )
    }
}

private struct BitwardenTokenPayload {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval
    let key: String?

    static func decode(_ data: Data) throws -> BitwardenTokenPayload {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = jsonString(root, "access_token", "AccessToken") else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        return BitwardenTokenPayload(
            accessToken: accessToken,
            refreshToken: jsonString(root, "refresh_token", "RefreshToken"),
            expiresIn: TimeInterval(jsonInt(root, "expires_in", "ExpiresIn") ?? 3600),
            key: jsonString(root, "key", "Key")
        )
    }

    static func containsTwoFactorChallenge(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let providers = root["TwoFactorProviders"] as? [Any], !providers.isEmpty {
            return true
        }
        if let providers = root["twoFactorProviders"] as? [Any], !providers.isEmpty {
            return true
        }
        if let providers = root["TwoFactorProviders"] as? [String: Any], !providers.isEmpty {
            return true
        }
        if let providers = root["twoFactorProviders"] as? [String: Any], !providers.isEmpty {
            return true
        }
        return false
    }

    static func twoFactorProviders(from data: Data) -> [BitwardenTwoFactorProvider] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var providersByID: [Int: BitwardenTwoFactorProvider] = [:]
        for key in ["TwoFactorProviders", "twoFactorProviders"] {
            if let values = root[key] as? [Any] {
                values.compactMap(providerID).forEach { id in
                    providersByID[id] = BitwardenTwoFactorProvider(providerID: id)
                }
            }
            if let values = root[key] as? [String: Any] {
                values.forEach { rawID, value in
                    guard let id = Int(rawID) else { return }
                    let name = (value as? [String: Any]).flatMap { jsonString($0, "name", "Name") }
                    providersByID[id] = BitwardenTwoFactorProvider(providerID: id, displayName: name)
                }
            }
        }
        for key in ["TwoFactorProviders2", "twoFactorProviders2"] {
            if let values = root[key] as? [String: Any] {
                values.keys.compactMap(Int.init).forEach { id in
                    providersByID[id] = providersByID[id] ?? BitwardenTwoFactorProvider(providerID: id)
                }
            }
        }
        return providersByID.keys.sorted().map { providersByID[$0] ?? BitwardenTwoFactorProvider(providerID: $0) }
    }

    private static func providerID(_ value: Any) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let stringValue = value as? String {
            return Int(stringValue)
        }
        return nil
    }
}

public struct BitwardenTokenRefreshRequest: Sendable, Equatable {
    public let identityURL: URL
    public let refreshToken: String

    public init(identityURL: URL, refreshToken: String) {
        self.identityURL = identityURL
        self.refreshToken = refreshToken
    }
}

public struct BitwardenTokenRefreshResult: Sendable, Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: TimeInterval

    public init(accessToken: String, refreshToken: String?, expiresIn: TimeInterval) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
    }
}

public protocol BitwardenIdentityTokenTransport: Sendable {
    func refreshAccessToken(_ request: BitwardenTokenRefreshRequest) async throws -> BitwardenTokenRefreshResult
}

public struct RefreshingBitwardenAccessTokenProvider: Sendable {
    private let sessionStore: any BitwardenAuthenticationSessionStore
    private let identityTransport: any BitwardenIdentityTokenTransport
    private let now: @Sendable () -> Date

    public init(
        sessionStore: any BitwardenAuthenticationSessionStore,
        identityTransport: any BitwardenIdentityTokenTransport = URLSessionBitwardenIdentityTokenTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sessionStore = sessionStore
        self.identityTransport = identityTransport
        self.now = now
    }

    public func accessToken() async throws -> String {
        guard let session = try sessionStore.loadSession() else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        guard session.isAccessTokenExpired(now: now()) else {
            return session.accessToken
        }
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        let result = try await identityTransport.refreshAccessToken(
            BitwardenTokenRefreshRequest(identityURL: session.identityURL, refreshToken: refreshToken)
        )
        let refreshed = session.refreshed(
            accessToken: result.accessToken,
            refreshToken: result.refreshToken,
            expiresIn: result.expiresIn,
            now: now()
        )
        try sessionStore.saveSession(refreshed)
        return refreshed.accessToken
    }
}

public final class URLSessionBitwardenIdentityTokenTransport: BitwardenIdentityTokenTransport, @unchecked Sendable {
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared, decoder: JSONDecoder = JSONDecoder()) {
        self.session = session
        self.decoder = decoder
    }

    public func refreshAccessToken(_ request: BitwardenTokenRefreshRequest) async throws -> BitwardenTokenRefreshResult {
        var components = URLComponents(url: request.identityURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = ([basePath, "connect/token"].filter { !$0.isEmpty }).joined(separator: "/")
        guard let url = components?.url else {
            throw BitwardenSyncProviderError.unsupportedOperation
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("desktop", forHTTPHeaderField: "Bitwarden-Client-Name")
        urlRequest.setValue("2025.9.1", forHTTPHeaderField: "Bitwarden-Client-Version")
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = formURLEncodedBody([
            ("grant_type", "refresh_token"),
            ("refresh_token", request.refreshToken),
            ("client_id", "desktop")
        ])
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BitwardenSyncProviderError.unsupportedOperation
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        let payload = try decoder.decode(BitwardenTokenRefreshPayload.self, from: data)
        return BitwardenTokenRefreshResult(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresIn: TimeInterval(payload.expiresIn)
        )
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

private struct BitwardenTokenRefreshPayload: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

public struct BitwardenSendSyncPlan: Sendable, Equatable {
    public let mutations: [BitwardenSyncMutation]
    public let conflicts: [BitwardenSyncConflict]
    public let updatedStates: [String: BitwardenSendSyncState]

    public init(
        mutations: [BitwardenSyncMutation],
        conflicts: [BitwardenSyncConflict],
        updatedStates: [String: BitwardenSendSyncState]
    ) {
        self.mutations = mutations
        self.conflicts = conflicts
        self.updatedStates = updatedStates
    }
}

public struct BitwardenItemSyncPlan: Sendable, Equatable {
    public let mutations: [BitwardenSyncMutation]
    public let conflicts: [BitwardenSyncConflict]
    public let updatedStates: [String: BitwardenItemSyncState]

    public init(
        mutations: [BitwardenSyncMutation],
        conflicts: [BitwardenSyncConflict],
        updatedStates: [String: BitwardenItemSyncState]
    ) {
        self.mutations = mutations
        self.conflicts = conflicts
        self.updatedStates = updatedStates
    }
}

public struct BitwardenItemSyncPlanner: Sendable {
    public init() {}

    public func plan(
        localItems: [BitwardenLocalItemSyncItem],
        deletedLocalItems: [BitwardenLocalItemSyncItem],
        remoteItems: [BitwardenSyncItem],
        previousStates: [BitwardenItemSyncState]
    ) -> BitwardenItemSyncPlan {
        let statesByLocalID = Dictionary(uniqueKeysWithValues: previousStates.map { ($0.localID, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteItems.map { ($0.remoteID, $0) })
        let localIDs = Set(localItems.map(\.localID))
        var mutations: [BitwardenSyncMutation] = []
        var conflicts: [BitwardenSyncConflict] = []
        var updatedStates = statesByLocalID

        for item in localItems {
            let state = statesByLocalID[item.localID]
            let fingerprint = item.syncFingerprint
            let remoteItem = remoteByID[state?.remoteID ?? ""]
            if let remoteID = state?.remoteID,
               remoteByID[remoteID] == nil,
               fingerprint != state?.lastSyncedFingerprint {
                conflicts.append(
                    BitwardenSyncConflict(
                        localID: item.localID,
                        remoteID: remoteID,
                        title: item.title,
                        reason: .remoteDeleted
                    )
                )
                continue
            }

            if state?.isDeleted == true,
               remoteItem?.deletedAt != nil {
                mutations.append(
                    .restoreCipher(
                        localID: item.localID,
                        remoteID: state?.remoteID,
                        kind: state?.kind ?? item.kind,
                        title: item.title
                    )
                )
                if fingerprint != state?.lastSyncedFingerprint {
                    mutations.append(.upsertCipher(item: item, remoteID: state?.remoteID))
                }
                updatedStates[item.localID] = BitwardenItemSyncState(
                    localID: item.localID,
                    remoteID: state?.remoteID,
                    kind: item.kind,
                    lastSyncedFingerprint: fingerprint,
                    lastRemoteRevision: remoteItem?.updatedAt.map { String($0.timeIntervalSince1970) } ?? state?.lastRemoteRevision,
                    isDeleted: false
                )
                continue
            }

            if state?.isDeleted == true || fingerprint != state?.lastSyncedFingerprint {
                mutations.append(.upsertCipher(item: item, remoteID: state?.remoteID))
                updatedStates[item.localID] = BitwardenItemSyncState(
                    localID: item.localID,
                    remoteID: state?.remoteID,
                    kind: item.kind,
                    lastSyncedFingerprint: fingerprint,
                    lastRemoteRevision: remoteItem?.updatedAt.map { String($0.timeIntervalSince1970) } ?? state?.lastRemoteRevision,
                    isDeleted: false
                )
            }
        }

        for item in deletedLocalItems {
            guard let state = statesByLocalID[item.localID] else {
                continue
            }
            mutations.append(
                .deleteCipher(
                    localID: item.localID,
                    remoteID: state.remoteID,
                    kind: state.kind,
                    title: item.title
                )
            )
            updatedStates[item.localID] = BitwardenItemSyncState(
                localID: item.localID,
                remoteID: state.remoteID,
                kind: state.kind,
                lastSyncedFingerprint: item.syncFingerprint,
                lastRemoteRevision: state.lastRemoteRevision,
                isDeleted: true
            )
        }

        for state in previousStates where !localIDs.contains(state.localID) && !state.isDeleted {
            guard let remoteID = state.remoteID,
                  remoteByID[remoteID] == nil,
                  !deletedLocalItems.contains(where: { $0.localID == state.localID })
            else {
                continue
            }
            updatedStates[state.localID] = BitwardenItemSyncState(
                localID: state.localID,
                remoteID: state.remoteID,
                kind: state.kind,
                lastSyncedFingerprint: state.lastSyncedFingerprint,
                lastRemoteRevision: state.lastRemoteRevision,
                isDeleted: true
            )
        }

        return BitwardenItemSyncPlan(
            mutations: mutations,
            conflicts: conflicts,
            updatedStates: updatedStates
        )
    }
}

public struct BitwardenSendSyncPlanner: Sendable {
    public init() {}

    public func plan(
        localSends: [BitwardenLocalSendSyncItem],
        deletedLocalSends: [BitwardenLocalSendSyncItem],
        remoteSends: [BitwardenSendSyncItem],
        previousStates: [BitwardenSendSyncState]
    ) -> BitwardenSendSyncPlan {
        let statesByLocalID = Dictionary(uniqueKeysWithValues: previousStates.map { ($0.localID, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteSends.map { ($0.remoteID, $0) })
        var mutations: [BitwardenSyncMutation] = []
        var conflicts: [BitwardenSyncConflict] = []
        var updatedStates = statesByLocalID
        let localIDs = Set(localSends.map(\.localID))

        for item in localSends {
            let state = statesByLocalID[item.localID]
            let fingerprint = item.syncFingerprint
            if let remoteID = state?.remoteID,
               remoteByID[remoteID] == nil,
               fingerprint != state?.lastSyncedFingerprint {
                conflicts.append(
                    BitwardenSyncConflict(
                        localID: item.localID,
                        remoteID: remoteID,
                        title: item.title,
                        reason: .remoteDeleted
                    )
                )
                continue
            }

            if state?.isDeleted == true || fingerprint != state?.lastSyncedFingerprint {
                mutations.append(
                    .upsertSend(
                        localID: item.localID,
                        remoteID: state?.remoteID,
                        title: item.title,
                        body: item.body,
                        notes: item.notes,
                        expiresAt: item.expiresAt,
                        maxViews: item.maxViews
                    )
                )
                updatedStates[item.localID] = BitwardenSendSyncState(
                    localID: item.localID,
                    remoteID: state?.remoteID,
                    lastSyncedFingerprint: fingerprint,
                    lastRemoteRevision: remoteByID[state?.remoteID ?? ""]?.updatedAt.map { String($0.timeIntervalSince1970) } ?? state?.lastRemoteRevision,
                    isDeleted: false
                )
            }
        }

        for item in deletedLocalSends {
            guard let state = statesByLocalID[item.localID] else {
                continue
            }
            mutations.append(
                .deleteSend(
                    localID: item.localID,
                    remoteID: state.remoteID,
                    title: item.title
                )
            )
            updatedStates[item.localID] = BitwardenSendSyncState(
                localID: item.localID,
                remoteID: state.remoteID,
                lastSyncedFingerprint: item.syncFingerprint,
                lastRemoteRevision: state.lastRemoteRevision,
                isDeleted: true
            )
        }

        for state in previousStates where !localIDs.contains(state.localID) && !state.isDeleted {
            guard let remoteID = state.remoteID,
                  remoteByID[remoteID] == nil,
                  !deletedLocalSends.contains(where: { $0.localID == state.localID })
            else {
                continue
            }
            updatedStates[state.localID] = BitwardenSendSyncState(
                localID: state.localID,
                remoteID: state.remoteID,
                lastSyncedFingerprint: state.lastSyncedFingerprint,
                lastRemoteRevision: state.lastRemoteRevision,
                isDeleted: true
            )
        }

        return BitwardenSendSyncPlan(
            mutations: mutations,
            conflicts: conflicts,
            updatedStates: updatedStates
        )
    }
}

public struct BitwardenVaultSyncRequest: Sendable, Equatable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data?

    public init(method: String, url: URL, headers: [String: String], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct BitwardenVaultSyncResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public struct BitwardenAttachmentUploadRequest: Sendable, Equatable {
    public let cipherRemoteID: String
    public let encryptedFileName: String
    public let encryptedKey: String
    public let encryptedContent: Data
    public let originalByteCount: Int
    public let mediaType: String

    public init(
        cipherRemoteID: String,
        encryptedFileName: String,
        encryptedKey: String,
        encryptedContent: Data,
        originalByteCount: Int,
        mediaType: String
    ) {
        self.cipherRemoteID = cipherRemoteID
        self.encryptedFileName = encryptedFileName
        self.encryptedKey = encryptedKey
        self.encryptedContent = encryptedContent
        self.originalByteCount = originalByteCount
        self.mediaType = mediaType
    }

    public var redactedSummary: String {
        "Bitwarden 附件待上传 \(encryptedContent.count) 字节"
    }
}

public struct BitwardenAttachmentUploadResult: Sendable, Equatable {
    public let attachmentRemoteID: String
    public let encryptedByteCount: Int

    public init(attachmentRemoteID: String, encryptedByteCount: Int) {
        self.attachmentRemoteID = attachmentRemoteID
        self.encryptedByteCount = encryptedByteCount
    }

    public var redactedSummary: String {
        "Bitwarden 附件已上传 \(encryptedByteCount) 字节"
    }
}

public struct BitwardenAttachmentDownloadRequest: Sendable, Equatable {
    public let cipherRemoteID: String
    public let attachmentRemoteID: String

    public init(cipherRemoteID: String, attachmentRemoteID: String) {
        self.cipherRemoteID = cipherRemoteID
        self.attachmentRemoteID = attachmentRemoteID
    }
}

public struct BitwardenAttachmentDownloadResult: Sendable, Equatable {
    public let encryptedContent: Data

    public init(encryptedContent: Data) {
        self.encryptedContent = encryptedContent
    }

    public var redactedSummary: String {
        "Bitwarden 附件已下载 \(encryptedContent.count) 字节"
    }
}

// MARK: - Bitwarden Send 链接与接收

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

public protocol BitwardenSyncProvider: Sendable {
    func pullSnapshot() async throws -> BitwardenSyncSnapshot
    /// 远端最新修订标记；不支持增量查询的实现返回 nil。
    func latestRevision() async throws -> BitwardenSyncRevision?
    /// 带增量判断的拉取：远端修订没有变化时返回 `.unchanged`，避免整库重复导入。
    func pullSnapshot(ifChangedSince revision: BitwardenSyncRevision?) async throws -> BitwardenSyncPullOutcome
    func pushMutations(_ mutations: [BitwardenSyncMutation]) async throws -> BitwardenSyncPushResult
    func uploadAttachment(_ request: BitwardenAttachmentUploadRequest) async throws -> BitwardenAttachmentUploadResult
    func downloadAttachment(_ request: BitwardenAttachmentDownloadRequest) async throws -> BitwardenAttachmentDownloadResult
    /// 匿名接收一个 Send（不需要登录），用于「打开别人发来的链接」。
    func fetchSend(_ request: BitwardenSendFetchRequest) async throws -> BitwardenReceivedSend
    /// 创建文本型 Send，并返回可分享链接（链接里携带 key material）。
    func createTextSend(_ request: BitwardenTextSendCreateRequest) async throws -> BitwardenTextSendCreateResult
}

public extension BitwardenSyncProvider {
    func latestRevision() async throws -> BitwardenSyncRevision? {
        nil
    }

    func pullSnapshot(ifChangedSince revision: BitwardenSyncRevision?) async throws -> BitwardenSyncPullOutcome {
        .changed(snapshot: try await pullSnapshot(), revision: nil)
    }

    func uploadAttachment(_ request: BitwardenAttachmentUploadRequest) async throws -> BitwardenAttachmentUploadResult {
        throw BitwardenSyncProviderError.unsupportedOperation
    }

    func downloadAttachment(_ request: BitwardenAttachmentDownloadRequest) async throws -> BitwardenAttachmentDownloadResult {
        throw BitwardenSyncProviderError.unsupportedOperation
    }

    func fetchSend(_ request: BitwardenSendFetchRequest) async throws -> BitwardenReceivedSend {
        throw BitwardenSyncProviderError.unsupportedOperation
    }

    func createTextSend(_ request: BitwardenTextSendCreateRequest) async throws -> BitwardenTextSendCreateResult {
        throw BitwardenSyncProviderError.unsupportedOperation
    }
}

public struct DefaultBitwardenSyncProvider: BitwardenSyncProvider {
    public init() {}

    public func pullSnapshot() async throws -> BitwardenSyncSnapshot {
        throw BitwardenSyncProviderError.authenticationRequired
    }

    public func pushMutations(_ mutations: [BitwardenSyncMutation]) async throws -> BitwardenSyncPushResult {
        throw BitwardenSyncProviderError.authenticationRequired
    }
}

public enum BitwardenSyncProviderError: Error, Sendable, Equatable, LocalizedError {
    case authenticationRequired
    case unsupportedOperation
    case unsupportedKDF(Int)
    case twoFactorRequired
    case serverRejected(statusCode: Int)
    case invalidServerURL
    case invalidResponse
    /// Send 链接无效、已过期或已被查看次数耗尽。
    case sendUnavailable

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            "Bitwarden 需要先登录。"
        case .unsupportedOperation:
            "Bitwarden 同步暂时无法执行该操作。"
        case .unsupportedKDF(let rawValue):
            "Bitwarden KDF \(rawValue) 暂时无法使用。"
        case .twoFactorRequired:
            "Bitwarden 需要两步验证，请完成验证后重试。"
        case .serverRejected(let statusCode):
            "Bitwarden 同步失败：服务器返回 \(statusCode)。"
        case .sendUnavailable:
            "Send 链接无效、已过期或已达最大查看次数。"
        case .invalidServerURL:
            "Bitwarden 服务器 URL 无效，仅支持 http/https。"
        case .invalidResponse:
            "Bitwarden 同步响应无法解析。"
        }
    }
}

enum BitwardenVaultSyncSnapshotParser {
    static func parse(_ data: Data, fallbackAccountLabel: String, vaultKey: BitwardenVaultKey? = nil) throws -> BitwardenSyncSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        let profile = dictionary(root, "profile", "Profile")
        let folders = array(root, "folders", "Folders")
        let collections = array(root, "collections", "Collections")
        let ciphers = array(root, "ciphers", "Ciphers")
        let sends = array(root, "sends", "Sends")
        let folderItems = folders.compactMap { folder -> BitwardenSyncFolder? in
            guard let id = string(folder, "id", "Id"), !id.isEmpty else { return nil }
            return BitwardenSyncFolder(
                remoteID: id,
                name: decryptedString(folder, "name", "Name", key: vaultKey) ?? "",
                updatedAt: date(string(folder, "revisionDate", "RevisionDate"))
            )
        }
        let folderNamesByID = Dictionary(uniqueKeysWithValues: folderItems.map { ($0.remoteID, $0.name) })
        let collectionItems = collections.compactMap { collection -> BitwardenSyncCollection? in
            guard let id = string(collection, "id", "Id"), !id.isEmpty else { return nil }
            return BitwardenSyncCollection(
                remoteID: id,
                name: decryptedString(collection, "name", "Name", key: vaultKey) ?? "",
                organizationID: string(collection, "organizationId", "OrganizationId"),
                isDefault: bool(collection, "default", "Default") ?? false
            )
        }
        let collectionNamesByID = Dictionary(uniqueKeysWithValues: collectionItems.map { ($0.remoteID, $0.name) })
        let items = ciphers.compactMap { cipher -> BitwardenSyncItem? in
            guard let id = string(cipher, "id", "Id"), !id.isEmpty else { return nil }
            let effectiveKey: BitwardenVaultKey?
            if let vaultKey,
               let itemKey = string(cipher, "key", "Key"),
               !itemKey.isEmpty {
                effectiveKey = try? BitwardenCrypto.decryptSymmetricKey(itemKey, key: vaultKey)
            } else {
                effectiveKey = vaultKey
            }
            let folderID = string(cipher, "folderId", "FolderId")
            let collectionIDs = stringArray(cipher, "collectionIds", "CollectionIds")
            let collectionNames = collectionIDs
                .compactMap { collectionNamesByID[$0] }
                .filter { !$0.isEmpty }
            let login = dictionary(cipher, "login", "Login")
            let card = dictionary(cipher, "card", "Card")
            let identity = dictionary(cipher, "identity", "Identity")
            let sshKey = dictionary(cipher, "sshKey", "SshKey", "SSHKey")
            let customFields = customFields(cipher, key: effectiveKey)
            let customFieldItems = customFieldItems(cipher, key: effectiveKey)
            let fido2Credential = array(login, "fido2Credentials", "Fido2Credentials").first ?? [:]
            let type = int(cipher, "type", "Type") ?? 1
            let kind = itemKind(
                for: type,
                hasFido2Credential: !fido2Credential.isEmpty,
                hasLegacySshKeyFields: hasLegacySshKeyFields(customFields)
            )
            let firstURI = array(login, "uris", "Uris").first
            let attachments = array(cipher, "attachments", "Attachments").compactMap { attachment -> BitwardenSyncAttachment? in
                guard let attachmentID = string(attachment, "id", "Id"), !attachmentID.isEmpty else { return nil }
                return BitwardenSyncAttachment(
                    remoteID: attachmentID,
                    cipherRemoteID: id,
                    fileName: decryptedString(attachment, "fileName", "FileName", key: effectiveKey) ?? "",
                    encryptedKey: string(attachment, "key", "Key"),
                    byteCount: int(attachment, "size", "Size") ?? 0
                )
            }
            let notes = decryptedString(cipher, "notes", "Notes", key: effectiveKey)
            return BitwardenSyncItem(
                remoteID: id,
                kind: kind,
                title: decryptedString(cipher, "name", "Name", key: effectiveKey) ?? "",
                username: decryptedString(login, "username", "Username", key: effectiveKey) ?? identityUsername(cipher, key: effectiveKey),
                url: firstURI.flatMap { decryptedString($0, "uri", "Uri", key: effectiveKey) } ?? "",
                password: decryptedString(login, "password", "Password", key: effectiveKey),
                totpSecret: decryptedString(login, "totp", "Totp", key: effectiveKey),
                notes: notes,
                folderID: folderID,
                folderName: folderID.flatMap { folderNamesByID[$0] },
                collectionNames: collectionNames,
                organizationID: string(cipher, "organizationId", "OrganizationId"),
                collectionIDs: collectionIDs,
                customFields: customFieldItems,
                attachments: attachments,
                attachmentByteCount: byteCount(array(cipher, "attachments", "Attachments")),
                updatedAt: date(string(cipher, "revisionDate", "RevisionDate")),
                favorite: bool(cipher, "favorite", "Favorite") ?? false,
                deletedAt: date(string(cipher, "deletedDate", "DeletedDate")),
                cardholderName: decryptedString(card, "cardholderName", "CardholderName", key: effectiveKey) ?? "",
                cardNumber: decryptedString(card, "number", "Number", key: effectiveKey) ?? "",
                cardExpiryMonth: decryptedString(card, "expMonth", "ExpMonth", key: effectiveKey) ?? "",
                cardExpiryYear: decryptedString(card, "expYear", "ExpYear", key: effectiveKey) ?? "",
                cardCode: decryptedString(card, "code", "Code", key: effectiveKey) ?? "",
                cardBrand: decryptedString(card, "brand", "Brand", key: effectiveKey) ?? "",
                identityFullName: identityFullName(identity, key: effectiveKey),
                identityDocumentNumber: decryptedString(identity, "passportNumber", "PassportNumber", key: effectiveKey)
                    ?? decryptedString(identity, "licenseNumber", "LicenseNumber", key: effectiveKey)
                    ?? "",
                identityIssuer: decryptedString(identity, "company", "Company", key: effectiveKey) ?? "",
                identityCountry: decryptedString(identity, "country", "Country", key: effectiveKey) ?? "",
                passkeyRelyingPartyID: decryptedString(fido2Credential, "rpId", "RpId", key: effectiveKey) ?? "",
                passkeyRelyingPartyName: decryptedString(fido2Credential, "rpName", "RpName", key: effectiveKey) ?? "",
                passkeyCredentialID: decryptedString(fido2Credential, "credentialId", "CredentialId", key: effectiveKey) ?? "",
                passkeyUserHandle: decryptedString(fido2Credential, "userHandle", "UserHandle", key: effectiveKey) ?? "",
                passkeyPublicKeyCOSE: passkeyMetadataValue("publicKeyCOSE", notes: notes),
                passkeyPrivateKeyReference: decryptedString(fido2Credential, "keyValue", "KeyValue", key: effectiveKey) ?? "",
                passkeyPublicKeyAlgorithm: decryptedString(fido2Credential, "keyAlgorithm", "KeyAlgorithm", key: effectiveKey) ?? "",
                passkeyCounter: decryptedString(fido2Credential, "counter", "Counter", key: effectiveKey) ?? "",
                passkeyDiscoverable: passkeyBoolean(decryptedString(fido2Credential, "discoverable", "Discoverable", key: effectiveKey)),
                passkeyCreationDate: string(fido2Credential, "creationDate", "CreationDate") ?? "",
                sshPublicKey: decryptedString(sshKey, "publicKey", "PublicKey", key: effectiveKey)
                    ?? sshPublicKey(from: customFields),
                sshPrivateKey: decryptedString(sshKey, "privateKey", "PrivateKey", key: effectiveKey)
                    ?? sshPrivateKey(from: customFields),
                sshKeyFingerprint: decryptedString(sshKey, "keyFingerprint", "KeyFingerprint", "fingerprint", "Fingerprint", key: effectiveKey)
                    ?? sshFingerprint(from: customFields)
            )
        }
        let sendItems = sends.compactMap { send -> BitwardenSendSyncItem? in
            guard let id = string(send, "id", "Id"), !id.isEmpty else { return nil }
            let text = dictionary(send, "text", "Text")
            let file = dictionary(send, "file", "File")
            let sendKey: BitwardenVaultKey?
            if let vaultKey,
               let encryptedKey = string(send, "key", "Key"),
               !encryptedKey.isEmpty,
               let keyMaterial = try? BitwardenCrypto.decrypt(encryptedKey, key: vaultKey) {
                sendKey = try? BitwardenCrypto.deriveSendKey(keyMaterial)
            } else {
                sendKey = vaultKey
            }
            let fileName = decryptedString(file, "fileName", "FileName", key: sendKey)
            return BitwardenSendSyncItem(
                remoteID: id,
                title: decryptedString(send, "name", "Name", key: sendKey) ?? fileName ?? "",
                body: decryptedString(text, "text", "Text", key: sendKey) ?? fileName ?? "",
                notes: decryptedString(send, "notes", "Notes", key: sendKey),
                expiresAt: string(send, "expirationDate", "ExpirationDate") ?? "",
                maxViews: int(send, "maxAccessCount", "MaxAccessCount") ?? 1,
                attachmentByteCount: byteCount([file]),
                updatedAt: date(string(send, "revisionDate", "RevisionDate"))
            )
        }
        return BitwardenSyncSnapshot(
            accountLabel: accountLabel(profile: profile, fallback: fallbackAccountLabel),
            revision: string(profile, "securityStamp", "SecurityStamp") ?? "",
            premiumSource: premiumSource(profile: profile),
            folders: folderItems,
            collections: collectionItems,
            items: items,
            sends: sendItems
        )
    }

    private static func premiumSource(profile: [String: Any]) -> BitwardenSyncSnapshot.PremiumSource {
        if bool(profile, "premiumFromOrganization", "PremiumFromOrganization") == true {
            return .organization
        }
        if bool(profile, "premium", "Premium") == true {
            return .account
        }
        return .none
    }

    private static func itemKind(
        for type: Int,
        hasFido2Credential: Bool = false,
        hasLegacySshKeyFields: Bool = false
    ) -> BitwardenSyncItemKind {
        switch type {
        case 2:
            .secureNote
        case 3:
            .card
        case 4:
            .identity
        case 5:
            .sshKey
        default:
            if hasLegacySshKeyFields {
                .sshKey
            } else {
                hasFido2Credential ? .passkey : .login
            }
        }
    }

    private static func customFields(_ cipher: [String: Any], key: BitwardenVaultKey?) -> [String: String] {
        array(cipher, "fields", "Fields").reduce(into: [String: String]()) { result, field in
            guard let name = decryptedString(field, "name", "Name", key: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                return
            }
            let value = decryptedString(field, "value", "Value", key: key) ?? ""
            result[name] = value
            result[name.lowercased()] = value
        }
    }

    /// 带类型的自定义字段列表（供只读展示与字段级合并使用）。
    /// Monica 自己写入的 `monica_*` 兼容字段不重复展示。
    private static func customFieldItems(_ cipher: [String: Any], key: BitwardenVaultKey?) -> [BitwardenSyncCustomField] {
        array(cipher, "fields", "Fields").compactMap { field -> BitwardenSyncCustomField? in
            guard let name = decryptedString(field, "name", "Name", key: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  !name.lowercased().hasPrefix("monica_") else {
                return nil
            }
            let rawType = int(field, "type", "Type") ?? 0
            let type: BitwardenSyncCustomFieldType = switch rawType {
            case 1: .hidden
            case 2: .boolean
            default: .text
            }
            return BitwardenSyncCustomField(
                name: name,
                value: decryptedString(field, "value", "Value", key: key) ?? "",
                type: type
            )
        }
    }

    private static func hasLegacySshKeyFields(_ fields: [String: String]) -> Bool {
        let loginType = customFieldValue(fields, "monica_login_type")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return loginType.compare("SSH_KEY", options: .caseInsensitive) == .orderedSame
            || !sshPublicKey(from: fields).isEmpty
            || !sshPrivateKey(from: fields).isEmpty
            || !sshFingerprint(from: fields).isEmpty
    }

    private static func sshPublicKey(from fields: [String: String]) -> String {
        let namedValue = customFieldValue(
            fields,
            "monica_ssh_public_key",
            "publicKey",
            "public_key",
            "public key",
            "public-key",
            "ssh public key",
            "ssh_public_key"
        )
        return nonBlank(namedValue) ?? fields.values.first(where: looksLikeSshPublicKey) ?? ""
    }

    private static func sshPrivateKey(from fields: [String: String]) -> String {
        let namedValue = customFieldValue(
            fields,
            "monica_ssh_private_key",
            "privateKey",
            "private_key",
            "private key",
            "private-key",
            "ssh private key",
            "ssh_private_key"
        )
        return nonBlank(namedValue) ?? fields.values.first(where: looksLikeSshPrivateKey) ?? ""
    }

    private static func sshFingerprint(from fields: [String: String]) -> String {
        let namedValue = customFieldValue(
            fields,
            "monica_ssh_fingerprint",
            "keyFingerprint",
            "key_fingerprint",
            "key fingerprint",
            "key-fingerprint",
            "fingerprint",
            "ssh fingerprint",
            "ssh_fingerprint"
        )
        return nonBlank(namedValue) ?? fields.values.first(where: looksLikeSshFingerprint) ?? ""
    }

    private static func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private static func customFieldValue(_ fields: [String: String], _ names: String...) -> String {
        for name in names {
            if let value = fields[name] ?? fields[name.lowercased()] {
                return value
            }
        }
        return ""
    }

    private static func looksLikeSshPublicKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("ssh-rsa ")
            || trimmed.hasPrefix("ssh-ed25519 ")
            || trimmed.hasPrefix("ecdsa-sha2-")
            || trimmed.hasPrefix("ssh-dss ")
    }

    private static func looksLikeSshPrivateKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("BEGIN OPENSSH PRIVATE KEY")
            || trimmed.contains("BEGIN RSA PRIVATE KEY")
            || trimmed.contains("BEGIN EC PRIVATE KEY")
            || trimmed.contains("BEGIN DSA PRIVATE KEY")
            || trimmed.contains("BEGIN PRIVATE KEY")
    }

    private static func looksLikeSshFingerprint(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("SHA256:")
            || trimmed.hasPrefix("MD5:")
    }

    private static func identityUsername(_ cipher: [String: Any], key: BitwardenVaultKey?) -> String {
        let identity = dictionary(cipher, "identity", "Identity")
        return decryptedString(identity, "username", "Username", key: key)
            ?? decryptedString(identity, "email", "Email", key: key)
            ?? ""
    }

    private static func identityFullName(_ identity: [String: Any], key: BitwardenVaultKey?) -> String {
        [
            decryptedString(identity, "title", "Title", key: key) ?? "",
            decryptedString(identity, "firstName", "FirstName", key: key) ?? "",
            decryptedString(identity, "middleName", "MiddleName", key: key) ?? "",
            decryptedString(identity, "lastName", "LastName", key: key) ?? ""
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    private static func decryptedString(_ json: [String: Any], _ keys: String..., key: BitwardenVaultKey?) -> String? {
        let rawValue = keys.lazy.compactMap { string(json, $0) }.first
        guard let rawValue else { return nil }
        guard BitwardenCipherString.isCipherString(rawValue) else {
            return rawValue
        }
        guard let key else { return nil }
        return try? BitwardenCrypto.decryptString(rawValue, key: key)
    }

    private static func passkeyBoolean(_ value: String?) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "false", "0", "no":
            false
        default:
            true
        }
    }

    private static func passkeyMetadataValue(_ key: String, notes: String?) -> String {
        guard let notes,
              notes.contains("[Monica Passkey Metadata]") else {
            return ""
        }
        let lines = notes.components(separatedBy: .newlines)
        guard let markerIndex = lines.firstIndex(of: "[Monica Passkey Metadata]") else {
            return ""
        }
        let prefix = "\(key):"
        return lines.dropFirst(markerIndex + 1)
            .first { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix) }
            .map { line in
                let value = line.dropFirst(prefix.count)
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
    }

    private static func accountLabel(profile: [String: Any], fallback: String) -> String {
        let name = string(profile, "name", "Name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            return name
        }
        let email = string(profile, "email", "Email")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let email, !email.isEmpty {
            return email
        }
        return fallback
    }

    private static func byteCount(_ values: [[String: Any]]) -> Int {
        values.reduce(0) { partial, value in
            partial + (int(value, "size", "Size") ?? 0)
        }
    }

    private static func dictionary(_ json: [String: Any], _ keys: String...) -> [String: Any] {
        for key in keys {
            if let value = json[key] as? [String: Any] {
                return value
            }
        }
        return [:]
    }

    private static func array(_ json: [String: Any], _ keys: String...) -> [[String: Any]] {
        for key in keys {
            if let value = json[key] as? [[String: Any]] {
                return value
            }
        }
        return []
    }

    private static func stringArray(_ json: [String: Any], _ keys: String...) -> [String] {
        for key in keys {
            if let values = json[key] as? [String] {
                return values
            }
            if let values = json[key] as? [Any] {
                return values.compactMap { value in
                    if let stringValue = value as? String {
                        return stringValue
                    }
                    if let number = value as? NSNumber {
                        return number.stringValue
                    }
                    return nil
                }
            }
        }
        return []
    }

    private static func string(_ json: [String: Any], _ keys: String...) -> String? {
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

    private static func int(_ json: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let value = json[key] as? Int {
                return value
            }
            if let value = json[key] as? Double {
                return Int(value)
            }
            if let value = json[key] as? String, let intValue = Int(value) {
                return intValue
            }
        }
        return nil
    }

    private static func bool(_ json: [String: Any], _ keys: String...) -> Bool? {
        for key in keys {
            if let value = json[key] as? Bool {
                return value
            }
            if let value = json[key] as? NSNumber {
                return value.boolValue
            }
            if let value = json[key] as? String {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1", "yes":
                    return true
                case "false", "0", "no":
                    return false
                default:
                    break
                }
            }
        }
        return nil
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}

public enum CloudFileProviderKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case oneDrive
    case googleDrive

    public var displayName: String {
        switch self {
        case .oneDrive:
            "OneDrive"
        case .googleDrive:
            "Google Drive"
        }
    }

    public var defaultBackupFileName: String {
        switch self {
        case .oneDrive:
            "monica-onedrive.mdbx"
        case .googleDrive:
            "monica-google-drive.mdbx"
        }
    }
}

func sanitizedBitwardenTitle(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "未命名" : trimmed
}

func sanitizedBitwardenText(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalizedBitwardenAccountLabel(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

func jsonString(_ json: [String: Any], _ keys: String...) -> String? {
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

func jsonInt(_ json: [String: Any], _ keys: String...) -> Int? {
    for key in keys {
        if let value = json[key] as? Int {
            return value
        }
        if let value = json[key] as? Double {
            return Int(value)
        }
        if let value = json[key] as? NSNumber {
            return value.intValue
        }
        if let value = json[key] as? String, let intValue = Int(value) {
            return intValue
        }
    }
    return nil
}

private extension Data {
    init?(bitwardenBase64Encoded value: String) {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: padded)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension URL {
    func appendingBitwardenPath(_ path: String) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + ([basePath, path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
            .filter { !$0.isEmpty }
            .joined(separator: "/"))
        components?.queryItems = nil
        return components?.url ?? self
    }
}

public enum CloudFileConnectionState: Sendable, Equatable {
    case disconnected
    case connected(accountLabel: String)
}

public struct CloudFileItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let path: String
    public let byteCount: Int
    public let modifiedAt: Date?
    public let sha256: String?
    public let revision: String?

    public init(
        id: String,
        name: String,
        path: String,
        byteCount: Int,
        modifiedAt: Date? = nil,
        sha256: String? = nil,
        revision: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
        self.revision = revision
    }

    public var redactedSummary: String {
        "\(sanitizedCloudFileName(name)) \(byteCount) 字节"
    }
}

public struct CloudFileDownload: Sendable, Equatable {
    public let item: CloudFileItem
    public let data: Data
    public let sha256: String
    public let revision: String?

    public init(item: CloudFileItem, data: Data, sha256: String? = nil, revision: String? = nil) {
        self.item = item
        self.data = data
        self.sha256 = sha256 ?? data.monicaSHA256Hex
        self.revision = revision ?? item.revision
    }

    public var redactedSummary: String {
        "\(sanitizedCloudFileName(item.name)) \(data.count) 字节"
    }
}

public struct CloudFileWriteReceipt: Sendable, Equatable {
    public let provider: CloudFileProviderKind
    public let itemID: String
    public let name: String
    public let byteCount: Int
    public let sha256: String
    public let revision: String?

    public init(
        provider: CloudFileProviderKind,
        itemID: String,
        name: String,
        byteCount: Int,
        sha256: String,
        revision: String? = nil
    ) {
        self.provider = provider
        self.itemID = itemID
        self.name = name
        self.byteCount = byteCount
        self.sha256 = sha256
        self.revision = revision
    }

    public var redactedSummary: String {
        "\(provider.displayName) \(sanitizedCloudFileName(name)) \(byteCount) 字节"
    }
}

public struct CloudFileDeleteReceipt: Sendable, Equatable {
    public let provider: CloudFileProviderKind
    public let itemID: String

    public init(provider: CloudFileProviderKind, itemID: String) {
        self.provider = provider
        self.itemID = itemID
    }

    public var redactedSummary: String {
        "\(provider.displayName) 已删除远端文件"
    }
}

public protocol CloudFileProvider: Sendable {
    var kind: CloudFileProviderKind { get }

    func connectionState() async throws -> CloudFileConnectionState
    func listFiles() async throws -> [CloudFileItem]
    func downloadFile(id: String) async throws -> CloudFileDownload
    func uploadFile(named fileName: String, data: Data) async throws -> CloudFileWriteReceipt
    func overwriteFile(id: String, data: Data, fileName: String, expectedRevision: String?) async throws -> CloudFileWriteReceipt
    func deleteFile(id: String) async throws -> CloudFileDeleteReceipt
    func renameFile(id: String, newName: String) async throws -> CloudFileWriteReceipt
}

public extension CloudFileProvider {
    func overwriteFile(id: String, data: Data, fileName: String) async throws -> CloudFileWriteReceipt {
        try await overwriteFile(id: id, data: data, fileName: fileName, expectedRevision: nil)
    }

    func deleteFile(id: String) async throws -> CloudFileDeleteReceipt {
        throw CloudFileProviderError.unsupportedOperation(provider: kind)
    }

    func renameFile(id: String, newName: String) async throws -> CloudFileWriteReceipt {
        throw CloudFileProviderError.unsupportedOperation(provider: kind)
    }
}

public enum CloudFileProviderError: Error, Sendable, Equatable, LocalizedError {
    case authenticationRequired(provider: CloudFileProviderKind)
    case itemNotFound(provider: CloudFileProviderKind)
    case unsupportedOperation(provider: CloudFileProviderKind)
    case conflict(provider: CloudFileProviderKind)
    case invalidDirectoryName(provider: CloudFileProviderKind)
    /// The provider needs developer-portal configuration (client ID, URL
    /// scheme). The UI disables the provider instead of failing the whole list.
    case notConfigured(provider: CloudFileProviderKind)

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired(let provider):
            "\(provider.displayName) 需要先登录。"
        case .itemNotFound(let provider):
            "\(provider.displayName) 未找到远端文件。"
        case .unsupportedOperation(let provider):
            "\(provider.displayName) 暂时无法执行该操作。"
        case .conflict(let provider):
            "\(provider.displayName) 远端文件已变化，请重新下载后再写回。"
        case .invalidDirectoryName(let provider):
            "\(provider.displayName) 目录名称无效，请使用字母、数字或空格。"
        case .notConfigured(let provider):
            "\(provider.displayName) 未配置，请先填写客户端 ID 与回调 scheme。"
        }
    }
}

public struct WebDAVEndpoint: Sendable, Equatable {
    public let baseURL: URL
    public let username: String
    public let password: String

    public init(
        baseURL: URL,
        username: String,
        password: String
    ) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }

    func url(for fileName: String) -> URL {
        baseURL.appendingPathComponent(fileName)
    }

    var authorizationHeader: String {
        let credentials = "\(username):\(password)"
        return "Basic \(Data(credentials.utf8).base64EncodedString())"
    }
}

public struct WebDAVBackupPackage: Sendable, Equatable {
    public let fileName: String
    public let data: Data
    public let sha256: String

    public init(fileName: String, data: Data) {
        self.fileName = fileName
        self.data = data
        self.sha256 = data.monicaSHA256Hex
    }
}

public struct WebDAVBackupReceipt: Sendable, Equatable {
    public let remoteURL: URL
    public let byteCount: Int
    public let sha256: String

    public init(remoteURL: URL, byteCount: Int, sha256: String) {
        self.remoteURL = remoteURL
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct WebDAVDownloadedBackup: Sendable, Equatable {
    public let fileName: String
    public let remoteURL: URL
    public let data: Data
    public let sha256: String

    public init(fileName: String, remoteURL: URL, data: Data, sha256: String) {
        self.fileName = fileName
        self.remoteURL = remoteURL
        self.data = data
        self.sha256 = sha256
    }
}

public struct WebDAVBackupItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let fileName: String
    public let byteCount: Int
    public let modifiedAt: Date?

    public init(
        fileName: String,
        byteCount: Int,
        modifiedAt: Date? = nil
    ) {
        let sanitized = sanitizedCloudFileName(fileName)
        self.id = sanitized
        self.fileName = sanitized
        self.byteCount = max(0, byteCount)
        self.modifiedAt = modifiedAt
    }

    public var isPermanent: Bool {
        let base = fileName.replacingOccurrences(of: ".mdbx", with: "")
        return base.hasSuffix("_permanent")
    }

    public var redactedSummary: String {
        "\(fileName) \(byteCount) 字节"
    }
}

public struct WebDAVRestorePreview: Sendable, Equatable {
    public let fileName: String
    public let byteCount: Int
    public let sha256: String

    public init(_ backup: WebDAVDownloadedBackup) throws {
        self.fileName = backup.fileName
        self.byteCount = backup.data.count
        self.sha256 = backup.sha256
    }
}

public struct WebDAVTransportRequest: Sendable, Equatable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data?

    public init(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct WebDAVTransportResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol WebDAVTransport {
    func send(_ request: WebDAVTransportRequest) async throws -> WebDAVTransportResponse
}

public struct WebDAVClient {
    private let endpoint: WebDAVEndpoint
    private let transport: any WebDAVTransport

    public init(endpoint: WebDAVEndpoint, transport: (any WebDAVTransport)? = nil) {
        self.endpoint = endpoint
        self.transport = transport ?? URLSessionWebDAVTransport(identity: WebDAVTrustIdentity(endpoint: endpoint))
    }

    public func upload(_ package: WebDAVBackupPackage) async throws -> WebDAVBackupReceipt {
        let remoteURL = endpoint.url(for: package.fileName)
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "PUT",
                url: remoteURL,
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Content-Type": "application/octet-stream",
                    "X-Monica-Backup-SHA256": package.sha256
                ],
                body: package.data
            )
        )

        guard [200, 201, 204].contains(response.statusCode) else {
            throw WebDAVError.unexpectedStatus(operation: "upload", statusCode: response.statusCode)
        }

        let checksumResponse = try await transport.send(
            WebDAVTransportRequest(
                method: "PUT",
                url: endpoint.url(for: package.sidecarFileName),
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Content-Type": "text/plain; charset=utf-8"
                ],
                body: Data("\(package.sha256)\n".utf8)
            )
        )
        guard [200, 201, 204].contains(checksumResponse.statusCode) else {
            throw WebDAVError.unexpectedStatus(
                operation: "upload checksum",
                statusCode: checksumResponse.statusCode
            )
        }

        return WebDAVBackupReceipt(
            remoteURL: remoteURL,
            byteCount: package.data.count,
            sha256: package.sha256
        )
    }

    public func download(fileName: String) async throws -> WebDAVDownloadedBackup {
        let remoteURL = endpoint.url(for: fileName)
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "GET",
                url: remoteURL,
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Accept": "application/octet-stream"
                ]
            )
        )

        guard response.statusCode == 200 else {
            throw WebDAVError.unexpectedStatus(operation: "download", statusCode: response.statusCode)
        }

        let computedSHA256 = response.body.monicaSHA256Hex
        let expectedSHA256: String
        if let headerSHA256 = response.headerValue("X-Monica-Backup-SHA256") {
            expectedSHA256 = headerSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            expectedSHA256 = try await downloadSidecarChecksum(fileName: fileName)
        }

        if expectedSHA256.lowercased() != computedSHA256 {
            throw WebDAVError.integrityCheckFailed
        }

        return WebDAVDownloadedBackup(
            fileName: fileName,
            remoteURL: remoteURL,
            data: response.body,
            sha256: computedSHA256
        )
    }

    public func listBackups() async throws -> [WebDAVBackupItem] {
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "PROPFIND",
                url: endpoint.baseURL,
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Depth": "1",
                    "Accept": "application/xml,text/xml"
                ]
            )
        )
        guard response.statusCode == 207 || response.statusCode == 200 else {
            throw WebDAVError.unexpectedStatus(operation: "list", statusCode: response.statusCode)
        }
        return Self.parseBackupItems(from: response.body)
            .filter { !$0.fileName.hasSuffix(".sha256") }
            .filter { $0.fileName.lowercased().hasSuffix(".mdbx") }
            .sorted(by: { lhs, rhs in
                switch (lhs.modifiedAt, rhs.modifiedAt) {
                case let (lhsDate?, rhsDate?):
                    if lhsDate == rhsDate { return lhs.fileName < rhs.fileName }
                    return lhsDate > rhsDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.fileName < rhs.fileName
                }
            })
    }

    public func deleteBackup(fileName: String) async throws {
        try await deleteFile(fileName: sanitizedCloudFileName(fileName), operation: "delete")
        do {
            try await deleteFile(
                fileName: WebDAVBackupPackage.sidecarFileName(for: sanitizedCloudFileName(fileName)),
                operation: "delete checksum"
            )
        } catch WebDAVError.unexpectedStatus(let operation, let statusCode)
            where operation == "delete checksum" && statusCode == 404 {
            return
        }
    }

    public func setBackupPermanent(fileName: String, isPermanent: Bool) async throws -> WebDAVBackupItem {
        let currentName = sanitizedCloudFileName(fileName)
        let nextName = permanentFileName(for: currentName, isPermanent: isPermanent)
        guard currentName != nextName else {
            return WebDAVBackupItem(fileName: currentName, byteCount: 0)
        }
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "MOVE",
                url: endpoint.url(for: currentName),
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Destination": endpoint.url(for: nextName).absoluteString,
                    "Overwrite": "F"
                ]
            )
        )
        guard [200, 201, 204].contains(response.statusCode) else {
            throw WebDAVError.unexpectedStatus(operation: "mark permanent", statusCode: response.statusCode)
        }
        return WebDAVBackupItem(fileName: nextName, byteCount: 0)
    }

    public func cleanupBackups(
        _ backups: [WebDAVBackupItem],
        olderThan cutoff: Date
    ) async throws -> [WebDAVBackupItem] {
        var deleted: [WebDAVBackupItem] = []
        for backup in backups where !backup.isPermanent {
            guard let modifiedAt = backup.modifiedAt, modifiedAt < cutoff else {
                continue
            }
            try await deleteBackup(fileName: backup.fileName)
            deleted.append(backup)
        }
        return deleted
    }

    private func downloadSidecarChecksum(fileName: String) async throws -> String {
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "GET",
                url: endpoint.url(for: WebDAVBackupPackage.sidecarFileName(for: fileName)),
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Accept": "text/plain"
                ]
            )
        )

        guard response.statusCode == 200 else {
            throw WebDAVError.unexpectedStatus(
                operation: "download checksum",
                statusCode: response.statusCode
            )
        }

        guard let checksum = String(data: response.body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !checksum.isEmpty
        else {
            throw WebDAVError.integrityCheckFailed
        }

        return checksum
    }

    private func deleteFile(fileName: String, operation: String) async throws {
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "DELETE",
                url: endpoint.url(for: fileName),
                headers: ["Authorization": endpoint.authorizationHeader]
            )
        )
        guard [200, 202, 204].contains(response.statusCode) else {
            throw WebDAVError.unexpectedStatus(operation: operation, statusCode: response.statusCode)
        }
    }

    private func permanentFileName(for fileName: String, isPermanent: Bool) -> String {
        let suffix = "_permanent"
        let extensionText = ".mdbx"
        guard fileName.lowercased().hasSuffix(extensionText) else {
            return isPermanent && !fileName.hasSuffix(suffix) ? fileName + suffix : fileName.replacingOccurrences(of: suffix, with: "")
        }
        let base = String(fileName.dropLast(extensionText.count))
        if isPermanent {
            return base.hasSuffix(suffix) ? fileName : "\(base)\(suffix)\(extensionText)"
        }
        return "\(base.replacingOccurrences(of: suffix, with: ""))\(extensionText)"
    }

    private static func parseBackupItems(from data: Data) -> [WebDAVBackupItem] {
        guard let xml = String(data: data, encoding: .utf8) else {
            return []
        }
        return xml
            .components(separatedBy: "</")
            .joined(separator: "</")
            .matches(pattern: #"<[^:>]*:?response\b[\s\S]*?</[^:>]*:?response>"#)
            .compactMap { response in
                guard let href = response.firstMatch(pattern: #"<[^:>]*:?href[^>]*>([\s\S]*?)</[^:>]*:?href>"#),
                      !response.contains("<d:collection") && !response.contains("<collection")
                else {
                    return nil
                }
                let fileName = href
                    .removingPercentEncoding?
                    .split(separator: "/")
                    .last
                    .map(String.init) ?? href
                let byteCount = response.firstMatch(pattern: #"<[^:>]*:?getcontentlength[^>]*>([\s\S]*?)</[^:>]*:?getcontentlength>"#)
                    .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
                let modifiedAt = response.firstMatch(pattern: #"<[^:>]*:?getlastmodified[^>]*>([\s\S]*?)</[^:>]*:?getlastmodified>"#)
                    .flatMap(Self.httpDate)
                return WebDAVBackupItem(fileName: fileName, byteCount: byteCount, modifiedAt: modifiedAt)
            }
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private extension WebDAVBackupPackage {
    var sidecarFileName: String {
        Self.sidecarFileName(for: fileName)
    }

    static func sidecarFileName(for fileName: String) -> String {
        "\(fileName).sha256"
    }
}

/// URLSession based WebDAV transport with Trust On First Use support for the
/// server certificate.
///
/// The transport never disables TLS validation globally: every request runs on an
/// ephemeral session whose delegate only answers `NSURLAuthenticationMethodServerTrust`.
/// A chain that the system trusts is handed back to URLSession untouched; a chain
/// the system rejects is accepted only when its SHA-256 fingerprint matches the pin
/// the user confirmed for this `host:port + user` scope.
public final class URLSessionWebDAVTransport: WebDAVTransport, @unchecked Sendable {
    public let identity: WebDAVTrustIdentity

    private let trustStore: any WebDAVCertificateTrustStore
    private let configuration: URLSessionConfiguration
    private let clock: @Sendable () -> Date

    public init(
        identity: WebDAVTrustIdentity,
        trustStore: any WebDAVCertificateTrustStore = KeychainWebDAVCertificateTrustStore(),
        configuration: URLSessionConfiguration = .ephemeral,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.identity = identity
        self.trustStore = trustStore
        self.configuration = configuration
        self.clock = now
    }

    public func send(_ request: WebDAVTransportRequest) async throws -> WebDAVTransportResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        request.headers.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let recorder = WebDAVServerTrustOutcomeRecorder()
        let delegate = WebDAVServerTrustDelegate(
            username: identity.username,
            trustStore: trustStore,
            recorder: recorder,
            now: clock
        )
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer {
            session.finishTasksAndInvalidate()
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw Self.translatedError(error, recorder: recorder)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.nonHTTPResponse
        }

        var headers: [String: String] = [:]
        httpResponse.allHeaderFields.forEach { key, value in
            guard let key = key as? String else {
                return
            }
            headers[key] = "\(value)"
        }

        return WebDAVTransportResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: data
        )
    }

    /// URLSession reports a cancelled trust challenge as a generic connection
    /// error; the delegate leaves the actionable decision in the recorder.
    private static func translatedError(
        _ error: Error,
        recorder: WebDAVServerTrustOutcomeRecorder
    ) -> Error {
        switch recorder.currentOutcome() {
        case .blocked(let challenge):
            if challenge.state == .mismatch {
                return WebDAVError.certificateFingerprintChanged(challenge)
            }
            return WebDAVError.untrustedCertificate(challenge)
        case .trustStoreUnavailable:
            return WebDAVError.certificateTrustStoreUnavailable
        case .inspectionFailed:
            return WebDAVError.certificateInspectionFailed
        case .systemTrusted, .pinned, .none:
            return error
        }
    }
}

public enum WebDAVError: Error, Sendable, Equatable, LocalizedError {
    case unexpectedStatus(operation: String, statusCode: Int)
    case integrityCheckFailed
    case nonHTTPResponse
    /// First connection to a self-signed / privately issued server: the user has
    /// to look at the fingerprint and confirm before anything is sent.
    case untrustedCertificate(WebDAVCertificateChallenge)
    /// The pinned fingerprint no longer matches. Never auto-accepted.
    case certificateFingerprintChanged(WebDAVCertificateChallenge)
    case certificateTrustStoreUnavailable
    case certificateInspectionFailed

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let operation, let statusCode):
            return "WebDAV \(operation) 失败，HTTP 状态码 \(statusCode)。"
        case .integrityCheckFailed:
            return "WebDAV 备份完整性校验失败。"
        case .nonHTTPResponse:
            return "WebDAV 服务器返回了非 HTTP 响应。"
        case .untrustedCertificate(let challenge):
            return "WebDAV 服务器证书未被系统信任（\(challenge.info.identity.displayAddress)）。SHA-256 指纹：\(challenge.info.displayFingerprint)。"
        case .certificateFingerprintChanged(let challenge):
            return "WebDAV 服务器证书指纹已变更，连接已阻止（\(challenge.info.identity.displayAddress)）。当前指纹：\(challenge.info.displayFingerprint)。"
        case .certificateTrustStoreUnavailable:
            return "无法读取 WebDAV 证书信任记录，已阻止连接。"
        case .certificateInspectionFailed:
            return "无法读取 WebDAV 服务器证书，已阻止连接。"
        }
    }
}

private extension WebDAVTransportResponse {
    func headerValue(_ name: String) -> String? {
        headers.first { key, _ in
            key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

func sanitizedCloudFileName(_ value: String) -> String {
    let normalized = value
        .replacingOccurrences(of: "\\", with: "/")
        .split(separator: "/")
        .last
        .map(String.init) ?? value
    let sanitized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.isEmpty ? "未命名文件" : sanitized
}

private extension String {
    func matches(pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, range: range).compactMap { result in
            guard let matchRange = Range(result.range, in: self) else {
                return nil
            }
            return String(self[matchRange])
        }
    }

    func firstMatch(pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let result = regex.firstMatch(in: self, range: range),
              result.numberOfRanges > 1,
              let matchRange = Range(result.range(at: 1), in: self)
        else {
            return nil
        }
        return String(self[matchRange])
    }
}

extension Data {
    var monicaSHA256Hex: String {
        SHA256.hash(data: self).map { byte in
            String(format: "%02x", byte)
        }.joined()
    }
}
