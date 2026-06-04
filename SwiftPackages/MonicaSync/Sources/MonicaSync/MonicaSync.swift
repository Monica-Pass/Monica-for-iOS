import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum MonicaSyncBaseline {
    public static let firstBackupProvider = "WebDAV"
}

public enum BitwardenSyncItemKind: String, Sendable, Equatable, Hashable, Codable {
    case login
    case secureNote
    case card
    case identity

    public var displayName: String {
        switch self {
        case .login:
            "login"
        case .secureNote:
            "note"
        case .card:
            "card"
        case .identity:
            "identity"
        }
    }
}

public struct BitwardenSyncItem: Sendable, Equatable, Identifiable {
    public var id: String { remoteID }

    public let remoteID: String
    public let kind: BitwardenSyncItemKind
    public let title: String
    public let username: String
    public let url: String
    public let password: String?
    public let totpSecret: String?
    public let notes: String?
    public let folderName: String?
    public let collectionNames: [String]
    public let attachmentByteCount: Int
    public let updatedAt: Date?
    public let cardholderName: String
    public let cardNumber: String
    public let cardExpiryMonth: String
    public let cardExpiryYear: String
    public let cardCode: String
    public let cardBrand: String
    public let identityFullName: String
    public let identityDocumentNumber: String
    public let identityIssuer: String
    public let identityCountry: String

    public init(
        remoteID: String,
        kind: BitwardenSyncItemKind,
        title: String,
        username: String = "",
        url: String = "",
        password: String? = nil,
        totpSecret: String? = nil,
        notes: String? = nil,
        folderName: String? = nil,
        collectionNames: [String] = [],
        attachmentByteCount: Int = 0,
        updatedAt: Date? = nil,
        cardholderName: String = "",
        cardNumber: String = "",
        cardExpiryMonth: String = "",
        cardExpiryYear: String = "",
        cardCode: String = "",
        cardBrand: String = "",
        identityFullName: String = "",
        identityDocumentNumber: String = "",
        identityIssuer: String = "",
        identityCountry: String = ""
    ) {
        self.remoteID = remoteID
        self.kind = kind
        self.title = title
        self.username = username
        self.url = url
        self.password = password
        self.totpSecret = totpSecret
        self.notes = notes
        self.folderName = folderName
        self.collectionNames = collectionNames
        self.attachmentByteCount = attachmentByteCount
        self.updatedAt = updatedAt
        self.cardholderName = cardholderName
        self.cardNumber = cardNumber
        self.cardExpiryMonth = cardExpiryMonth
        self.cardExpiryYear = cardExpiryYear
        self.cardCode = cardCode
        self.cardBrand = cardBrand
        self.identityFullName = identityFullName
        self.identityDocumentNumber = identityDocumentNumber
        self.identityIssuer = identityIssuer
        self.identityCountry = identityCountry
    }

    public var redactedSummary: String {
        [
            kind.displayName,
            sanitizedBitwardenTitle(title),
            sanitizedBitwardenText(username),
            attachmentByteCount > 0 ? "\(attachmentByteCount) 字节附件" : ""
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }
}

public struct BitwardenSendSyncItem: Sendable, Equatable, Identifiable {
    public var id: String { remoteID }

    public let remoteID: String
    public let title: String
    public let body: String
    public let notes: String?
    public let expiresAt: String
    public let maxViews: Int
    public let attachmentByteCount: Int
    public let updatedAt: Date?

    public init(
        remoteID: String,
        title: String,
        body: String,
        notes: String? = nil,
        expiresAt: String = "",
        maxViews: Int = 1,
        attachmentByteCount: Int = 0,
        updatedAt: Date? = nil
    ) {
        self.remoteID = remoteID
        self.title = title
        self.body = body
        self.notes = notes
        self.expiresAt = expiresAt
        self.maxViews = maxViews
        self.attachmentByteCount = attachmentByteCount
        self.updatedAt = updatedAt
    }

    public var redactedSummary: String {
        [
            "Send",
            sanitizedBitwardenTitle(title),
            "\(maxViews) 次",
            attachmentByteCount > 0 ? "\(attachmentByteCount) 字节附件" : ""
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }
}

public struct BitwardenSyncSnapshot: Sendable, Equatable {
    public let accountLabel: String
    public let revision: String
    public let items: [BitwardenSyncItem]
    public let sends: [BitwardenSendSyncItem]

    public init(
        accountLabel: String,
        revision: String,
        items: [BitwardenSyncItem] = [],
        sends: [BitwardenSendSyncItem] = []
    ) {
        self.accountLabel = accountLabel
        self.revision = revision
        self.items = items
        self.sends = sends
    }

    public var redactedSummary: String {
        "Bitwarden \(sanitizedBitwardenText(accountLabel))：\(items.count) 个条目，\(sends.count) 个 Send"
    }
}

public enum BitwardenSyncMutation: Sendable, Equatable {
    case upsertCipher(item: BitwardenLocalItemSyncItem, remoteID: String?)
    case deleteCipher(localID: String, remoteID: String?, kind: BitwardenSyncItemKind, title: String)
    case upsertSend(
        localID: String,
        remoteID: String?,
        title: String,
        body: String,
        notes: String?,
        expiresAt: String,
        maxViews: Int
    )
    case upsertEncryptedSend(
        localID: String,
        remoteID: String?,
        key: String,
        name: String,
        notes: String?,
        text: String,
        deletionDate: String,
        expirationDate: String?,
        maxAccessCount: Int?
    )
    case deleteSend(localID: String, remoteID: String?, title: String)

    public var redactedSummary: String {
        switch self {
        case .upsertCipher(let item, _):
            "upsert \(item.redactedSummary)"
        case .deleteCipher(_, _, let kind, let title):
            "delete \(kind.displayName) \(sanitizedBitwardenTitle(title))"
        case .upsertSend(_, _, let title, _, _, _, let maxViews):
            "upsert Send \(sanitizedBitwardenTitle(title)) \(maxViews) 次"
        case .upsertEncryptedSend:
            "upsert encrypted Send"
        case .deleteSend(_, _, let title):
            "delete Send \(sanitizedBitwardenTitle(title))"
        }
    }
}

public struct BitwardenLocalSendSyncItem: Sendable, Equatable, Identifiable {
    public var id: String { localID }

    public let localID: String
    public let title: String
    public let body: String
    public let notes: String?
    public let expiresAt: String
    public let maxViews: Int

    public init(
        localID: String,
        title: String,
        body: String,
        notes: String?,
        expiresAt: String,
        maxViews: Int
    ) {
        self.localID = localID
        self.title = title
        self.body = body
        self.notes = notes
        self.expiresAt = expiresAt
        self.maxViews = maxViews
    }

    public var syncFingerprint: String {
        [
            title,
            body,
            notes ?? "",
            expiresAt,
            String(maxViews)
        ].joined(separator: "\u{1F}")
    }
}

public struct BitwardenLocalItemSyncItem: Sendable, Equatable, Identifiable {
    public var id: String { localID }

    public let localID: String
    public let kind: BitwardenSyncItemKind
    public let title: String
    public let username: String
    public let url: String
    public let password: String?
    public let totpSecret: String?
    public let notes: String?
    public let folderID: String?
    public let folderName: String?
    public let cardholderName: String
    public let cardNumber: String
    public let cardExpiryMonth: String
    public let cardExpiryYear: String
    public let cardCode: String
    public let cardBrand: String
    public let identityFullName: String
    public let identityDocumentNumber: String
    public let identityIssuer: String
    public let identityCountry: String

    public init(
        localID: String,
        kind: BitwardenSyncItemKind,
        title: String,
        username: String = "",
        url: String = "",
        password: String? = nil,
        totpSecret: String? = nil,
        notes: String? = nil,
        folderID: String? = nil,
        folderName: String? = nil,
        cardholderName: String = "",
        cardNumber: String = "",
        cardExpiryMonth: String = "",
        cardExpiryYear: String = "",
        cardCode: String = "",
        cardBrand: String = "",
        identityFullName: String = "",
        identityDocumentNumber: String = "",
        identityIssuer: String = "",
        identityCountry: String = ""
    ) {
        self.localID = localID
        self.kind = kind
        self.title = title
        self.username = username
        self.url = url
        self.password = password
        self.totpSecret = totpSecret
        self.notes = notes
        self.folderID = folderID
        self.folderName = folderName
        self.cardholderName = cardholderName
        self.cardNumber = cardNumber
        self.cardExpiryMonth = cardExpiryMonth
        self.cardExpiryYear = cardExpiryYear
        self.cardCode = cardCode
        self.cardBrand = cardBrand
        self.identityFullName = identityFullName
        self.identityDocumentNumber = identityDocumentNumber
        self.identityIssuer = identityIssuer
        self.identityCountry = identityCountry
    }

    public var syncFingerprint: String {
        [
            kind.rawValue,
            title,
            username,
            url,
            password ?? "",
            totpSecret ?? "",
            notes ?? "",
            folderID ?? "",
            folderName ?? "",
            cardholderName,
            cardNumber,
            cardExpiryMonth,
            cardExpiryYear,
            cardCode,
            cardBrand,
            identityFullName,
            identityDocumentNumber,
            identityIssuer,
            identityCountry
        ].joined(separator: "\u{1F}")
    }

    public var redactedSummary: String {
        [
            kind.displayName,
            sanitizedBitwardenTitle(title),
            sanitizedBitwardenText(username)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }
}

public struct BitwardenSendSyncState: Sendable, Equatable, Codable, Identifiable {
    public var id: String { localID }

    public let localID: String
    public let remoteID: String?
    public let lastSyncedFingerprint: String
    public let lastRemoteRevision: String?
    public let isDeleted: Bool

    public init(
        localID: String,
        remoteID: String?,
        lastSyncedFingerprint: String,
        lastRemoteRevision: String?,
        isDeleted: Bool = false
    ) {
        self.localID = localID
        self.remoteID = remoteID
        self.lastSyncedFingerprint = lastSyncedFingerprint
        self.lastRemoteRevision = lastRemoteRevision
        self.isDeleted = isDeleted
    }

    public var redactedSummary: String {
        isDeleted ? "Send 同步状态 已删除" : "Send 同步状态 已关联"
    }
}

public struct BitwardenItemSyncState: Sendable, Equatable, Codable, Identifiable {
    public var id: String { localID }

    public let localID: String
    public let remoteID: String?
    public let kind: BitwardenSyncItemKind
    public let lastSyncedFingerprint: String
    public let lastRemoteRevision: String?
    public let isDeleted: Bool

    public init(
        localID: String,
        remoteID: String?,
        kind: BitwardenSyncItemKind,
        lastSyncedFingerprint: String,
        lastRemoteRevision: String?,
        isDeleted: Bool = false
    ) {
        self.localID = localID
        self.remoteID = remoteID
        self.kind = kind
        self.lastSyncedFingerprint = lastSyncedFingerprint
        self.lastRemoteRevision = lastRemoteRevision
        self.isDeleted = isDeleted
    }

    public var redactedSummary: String {
        isDeleted ? "\(kind.displayName) 同步状态 已删除" : "\(kind.displayName) 同步状态 已关联"
    }
}

public enum BitwardenSyncConflictReason: Sendable, Equatable {
    case bothModified
    case remoteDeleted
    case localDeleted

    public var displayName: String {
        switch self {
        case .bothModified:
            "本地和远端都已修改"
        case .remoteDeleted:
            "远端已删除"
        case .localDeleted:
            "本地已删除"
        }
    }
}

public struct BitwardenSyncConflict: Sendable, Equatable {
    public let localID: String?
    public let remoteID: String?
    public let title: String
    public let reason: BitwardenSyncConflictReason

    public init(
        localID: String? = nil,
        remoteID: String? = nil,
        title: String,
        reason: BitwardenSyncConflictReason
    ) {
        self.localID = localID
        self.remoteID = remoteID
        self.title = title
        self.reason = reason
    }

    public var redactedSummary: String {
        "冲突 \(sanitizedBitwardenTitle(title))：\(reason.displayName)"
    }
}

public struct BitwardenSyncPushResult: Sendable, Equatable {
    public let acceptedMutationCount: Int
    public let conflicts: [BitwardenSyncConflict]
    public let revision: String
    public let assignedRemoteIDs: [String: String]

    public init(
        acceptedMutationCount: Int,
        conflicts: [BitwardenSyncConflict] = [],
        revision: String = "",
        assignedRemoteIDs: [String: String] = [:]
    ) {
        self.acceptedMutationCount = acceptedMutationCount
        self.conflicts = conflicts
        self.revision = revision
        self.assignedRemoteIDs = assignedRemoteIDs
    }

    public var redactedSummary: String {
        "Bitwarden 已推送 \(acceptedMutationCount) 个变更，\(conflicts.count) 个冲突"
    }
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
        guard prelogin.kdf == .pbkdf2 else {
            throw BitwardenSyncProviderError.unsupportedKDF(prelogin.kdf.rawValue)
        }

        let masterKey = try BitwardenCrypto.deriveMasterKeyPBKDF2(
            password: masterPassword,
            salt: normalizedEmail.lowercased(),
            iterations: prelogin.iterations
        )
        let passwordHash = try BitwardenCrypto.deriveMasterPasswordHash(
            masterKey: masterKey,
            password: masterPassword
        )
        let stretchedKey = try BitwardenCrypto.stretchMasterKey(masterKey)
        let tokenResponse = try await transport.token(
            BitwardenTokenHTTPRequest(
                url: Self.tokenURL(identityURL: urls.identityURL),
                headers: [
                    "Auth-Email": Data(normalizedEmail.utf8).base64URLEncodedString(),
                    "device-type": "8",
                    "cache-control": "no-store",
                    "Bitwarden-Client-Name": "desktop",
                    "Bitwarden-Client-Version": "2025.9.1",
                    "Content-Type": "application/x-www-form-urlencoded"
                ],
                form: [
                    "grant_type": "password",
                    "username": normalizedEmail,
                    "password": passwordHash,
                    "scope": "api offline_access",
                    "client_id": "desktop",
                    "deviceIdentifier": deviceIdentifier(),
                    "deviceType": "8",
                    "deviceName": "linux"
                ]
            )
        )
        guard (200...299).contains(tokenResponse.statusCode) else {
            if BitwardenTokenPayload.containsTwoFactorChallenge(tokenResponse.body) {
                throw BitwardenSyncProviderError.twoFactorRequired
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
        return session
    }

    private static func preloginURL(identityURL: URL) -> URL {
        identityURL.appendingBitwardenPath("accounts/prelogin")
    }

    private static func tokenURL(identityURL: URL) -> URL {
        identityURL.appendingBitwardenPath("connect/token")
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
                mutations.append(.upsertCipher(item: item, remoteID: state?.remoteID))
                updatedStates[item.localID] = BitwardenItemSyncState(
                    localID: item.localID,
                    remoteID: state?.remoteID,
                    kind: item.kind,
                    lastSyncedFingerprint: fingerprint,
                    lastRemoteRevision: remoteByID[state?.remoteID ?? ""]?.updatedAt.map { String($0.timeIntervalSince1970) } ?? state?.lastRemoteRevision,
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

public protocol BitwardenVaultSyncTransport: Sendable {
    func send(_ request: BitwardenVaultSyncRequest) async throws -> BitwardenVaultSyncResponse
}

public struct BitwardenVaultSyncProvider: BitwardenSyncProvider {
    private let sessionStore: any BitwardenAuthenticationSessionStore
    private let accessTokenProvider: RefreshingBitwardenAccessTokenProvider
    private let vaultTransport: any BitwardenVaultSyncTransport
    private let vaultKeyStore: (any BitwardenVaultKeyStore)?

    public init(
        sessionStore: any BitwardenAuthenticationSessionStore,
        identityTransport: any BitwardenIdentityTokenTransport = URLSessionBitwardenIdentityTokenTransport(),
        vaultTransport: any BitwardenVaultSyncTransport = URLSessionBitwardenVaultSyncTransport(),
        vaultKeyStore: (any BitwardenVaultKeyStore)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sessionStore = sessionStore
        self.accessTokenProvider = RefreshingBitwardenAccessTokenProvider(
            sessionStore: sessionStore,
            identityTransport: identityTransport,
            now: now
        )
        self.vaultTransport = vaultTransport
        self.vaultKeyStore = vaultKeyStore
    }

    public func pullSnapshot() async throws -> BitwardenSyncSnapshot {
        guard let session = try sessionStore.loadSession() else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        let accessToken = try await accessTokenProvider.accessToken()
        let request = BitwardenVaultSyncRequest(
            method: "GET",
            url: Self.syncURL(apiURL: session.apiURL),
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json"
            ]
        )
        let response = try await vaultTransport.send(request)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        guard (200...299).contains(response.statusCode) else {
            throw BitwardenSyncProviderError.serverRejected(statusCode: response.statusCode)
        }
        return try BitwardenVaultSyncSnapshotParser.parse(
            response.body,
            fallbackAccountLabel: session.accountLabel,
            vaultKey: try vaultKeyStore?.loadVaultKey(accountLabel: session.accountLabel)
        )
    }

    public func pushMutations(_ mutations: [BitwardenSyncMutation]) async throws -> BitwardenSyncPushResult {
        guard let session = try sessionStore.loadSession() else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        guard !mutations.isEmpty else {
            let revision = String(session.expiresAt.timeIntervalSince1970)
            return BitwardenSyncPushResult(acceptedMutationCount: 0, conflicts: [], revision: revision)
        }
        let accessToken = try await accessTokenProvider.accessToken()
        let vaultKey = try vaultKeyStore?.loadVaultKey(accountLabel: session.accountLabel)
        var acceptedMutationCount = 0
        var latestRevision = ""
        var assignedRemoteIDs: [String: String] = [:]
        for mutation in mutations {
            let response = try await vaultTransport.send(
                try Self.request(
                    for: mutation,
                    apiURL: session.apiURL,
                    accessToken: accessToken,
                    vaultKey: vaultKey
                )
            )
            if response.statusCode == 401 || response.statusCode == 403 {
                throw BitwardenSyncProviderError.authenticationRequired
            }
            if case .deleteSend = mutation, response.statusCode == 404 {
                acceptedMutationCount += 1
                continue
            }
            if case .deleteCipher = mutation, response.statusCode == 404 {
                acceptedMutationCount += 1
                continue
            }
            guard (200...299).contains(response.statusCode) else {
                throw BitwardenSyncProviderError.serverRejected(statusCode: response.statusCode)
            }
            acceptedMutationCount += 1
            latestRevision = Self.revision(from: response) ?? latestRevision
            if let localID = Self.createdLocalID(for: mutation),
               let remoteID = Self.remoteID(from: response) {
                assignedRemoteIDs[localID] = remoteID
            }
        }
        return BitwardenSyncPushResult(
            acceptedMutationCount: acceptedMutationCount,
            conflicts: [],
            revision: latestRevision,
            assignedRemoteIDs: assignedRemoteIDs
        )
    }

    private static func syncURL(apiURL: URL) -> URL {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + ([basePath, "sync"].filter { !$0.isEmpty }).joined(separator: "/")
        components?.queryItems = [URLQueryItem(name: "excludeDomains", value: "true")]
        return components?.url ?? apiURL
    }

    private static func request(
        for mutation: BitwardenSyncMutation,
        apiURL: URL,
        accessToken: String,
        vaultKey: BitwardenVaultKey?
    ) throws -> BitwardenVaultSyncRequest {
        switch mutation {
        case .upsertCipher(let item, let remoteID):
            guard let vaultKey else {
                throw BitwardenSyncProviderError.authenticationRequired
            }
            let body = try JSONSerialization.data(
                withJSONObject: encryptedCipherPayload(for: item, key: vaultKey),
                options: [.sortedKeys]
            )
            return BitwardenVaultSyncRequest(
                method: remoteID == nil ? "POST" : "PUT",
                url: cipherURL(apiURL: apiURL, remoteID: remoteID),
                headers: jsonHeaders(accessToken: accessToken),
                body: body
            )
        case .deleteCipher(_, let remoteID, _, _):
            guard let remoteID, !remoteID.isEmpty else {
                throw BitwardenSyncProviderError.unsupportedOperation
            }
            return BitwardenVaultSyncRequest(
                method: "DELETE",
                url: cipherURL(apiURL: apiURL, remoteID: remoteID),
                headers: [
                    "Authorization": "Bearer \(accessToken)",
                    "Accept": "application/json"
                ]
            )
        case .upsertSend(_, let remoteID, let title, let body, let notes, let expiresAt, let maxViews):
            guard let vaultKey else {
                throw BitwardenSyncProviderError.authenticationRequired
            }
            let keyMaterial = try BitwardenCrypto.makeSendKeyMaterial()
            let sendKey = try BitwardenCrypto.deriveSendKey(keyMaterial)
            let normalizedExpirationDate = normalizedBitwardenSendDate(expiresAt)
            let deletionDate = normalizedExpirationDate ?? "9999-12-31T00:00:00Z"
            let payload: [String: Any] = [
                "key": try BitwardenCrypto.encrypt(keyMaterial, key: vaultKey),
                "type": 0,
                "name": try BitwardenCrypto.encryptString(title, key: sendKey),
                "notes": try notes.map { try BitwardenCrypto.encryptString($0, key: sendKey) } ?? NSNull(),
                "password": NSNull(),
                "disabled": false,
                "hideEmail": false,
                "deletionDate": deletionDate,
                "expirationDate": normalizedExpirationDate.map { $0 as Any } ?? NSNull(),
                "maxAccessCount": maxViews > 0 ? maxViews as Any : NSNull(),
                "text": [
                    "text": try BitwardenCrypto.encryptString(body, key: sendKey),
                    "hidden": false
                ]
            ]
            let body = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
            return BitwardenVaultSyncRequest(
                method: remoteID == nil ? "POST" : "PUT",
                url: sendURL(apiURL: apiURL, remoteID: remoteID),
                headers: jsonHeaders(accessToken: accessToken),
                body: body
            )
        case .upsertEncryptedSend(_, let remoteID, let key, let name, let notes, let text, let deletionDate, let expirationDate, let maxAccessCount):
            let payload: [String: Any] = [
                "key": key,
                "type": 0,
                "name": name,
                "notes": notes.map { $0 as Any } ?? NSNull(),
                "password": NSNull(),
                "disabled": false,
                "hideEmail": false,
                "deletionDate": deletionDate,
                "expirationDate": expirationDate.map { $0 as Any } ?? NSNull(),
                "maxAccessCount": maxAccessCount.map { $0 as Any } ?? NSNull(),
                "text": [
                    "text": text,
                    "hidden": false
                ]
            ]
            let body = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
            return BitwardenVaultSyncRequest(
                method: remoteID == nil ? "POST" : "PUT",
                url: sendURL(apiURL: apiURL, remoteID: remoteID),
                headers: jsonHeaders(accessToken: accessToken),
                body: body
            )
        case .deleteSend(_, let remoteID, _):
            guard let remoteID, !remoteID.isEmpty else {
                throw BitwardenSyncProviderError.unsupportedOperation
            }
            return BitwardenVaultSyncRequest(
                method: "DELETE",
                url: sendURL(apiURL: apiURL, remoteID: remoteID),
                headers: [
                    "Authorization": "Bearer \(accessToken)",
                    "Accept": "application/json"
                ]
            )
        }
    }

    public func uploadAttachment(_ request: BitwardenAttachmentUploadRequest) async throws -> BitwardenAttachmentUploadResult {
        guard let session = try sessionStore.loadSession() else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        let accessToken = try await accessTokenProvider.accessToken()
        let planBody = try JSONSerialization.data(
            withJSONObject: [
                "fileName": request.encryptedFileName,
                "key": request.encryptedKey,
                "fileSize": request.originalByteCount
            ] as [String: Any],
            options: [.sortedKeys]
        )
        let planResponse = try await vaultTransport.send(
            BitwardenVaultSyncRequest(
                method: "POST",
                url: Self.attachmentPlanURL(apiURL: session.apiURL, cipherRemoteID: request.cipherRemoteID),
                headers: Self.jsonHeaders(accessToken: accessToken),
                body: planBody
            )
        )
        if planResponse.statusCode == 401 || planResponse.statusCode == 403 {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        guard (200...299).contains(planResponse.statusCode),
              let plan = try JSONSerialization.jsonObject(with: planResponse.body) as? [String: Any],
              let attachmentID = Self.jsonString(plan, "attachmentId", "AttachmentId"),
              let uploadURLString = Self.jsonString(plan, "url", "Url"),
              let uploadURL = URL(string: uploadURLString) else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        let uploadResponse = try await vaultTransport.send(
            BitwardenVaultSyncRequest(
                method: "PUT",
                url: uploadURL,
                headers: [
                    "Content-Type": request.mediaType.isEmpty ? "application/octet-stream" : request.mediaType
                ],
                body: request.encryptedContent
            )
        )
        guard (200...299).contains(uploadResponse.statusCode) else {
            throw BitwardenSyncProviderError.serverRejected(statusCode: uploadResponse.statusCode)
        }
        return BitwardenAttachmentUploadResult(
            attachmentRemoteID: attachmentID,
            encryptedByteCount: request.encryptedContent.count
        )
    }

    public func downloadAttachment(_ request: BitwardenAttachmentDownloadRequest) async throws -> BitwardenAttachmentDownloadResult {
        guard let session = try sessionStore.loadSession() else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        let accessToken = try await accessTokenProvider.accessToken()
        let response = try await vaultTransport.send(
            BitwardenVaultSyncRequest(
                method: "GET",
                url: Self.attachmentDownloadURL(
                    apiURL: session.apiURL,
                    cipherRemoteID: request.cipherRemoteID,
                    attachmentRemoteID: request.attachmentRemoteID
                ),
                headers: [
                    "Authorization": "Bearer \(accessToken)",
                    "Accept": "application/octet-stream"
                ]
            )
        )
        if response.statusCode == 401 || response.statusCode == 403 {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        guard (200...299).contains(response.statusCode) else {
            throw BitwardenSyncProviderError.serverRejected(statusCode: response.statusCode)
        }
        return BitwardenAttachmentDownloadResult(encryptedContent: response.body)
    }

    private static func sendURL(apiURL: URL, remoteID: String?) -> URL {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + ([basePath, "sends", remoteID].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }).joined(separator: "/")
        components?.queryItems = nil
        return components?.url ?? apiURL
    }

    private static func normalizedBitwardenSendDate(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.contains("T") {
            return trimmed
        }
        return "\(trimmed)T00:00:00Z"
    }

    private static func cipherURL(apiURL: URL, remoteID: String?) -> URL {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + ([basePath, "ciphers", remoteID].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }).joined(separator: "/")
        components?.queryItems = nil
        return components?.url ?? apiURL
    }

    private static func attachmentPlanURL(apiURL: URL, cipherRemoteID: String) -> URL {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + [basePath, "ciphers", cipherRemoteID, "attachment", "v2"]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components?.queryItems = nil
        return components?.url ?? apiURL
    }

    private static func attachmentDownloadURL(apiURL: URL, cipherRemoteID: String, attachmentRemoteID: String) -> URL {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + [basePath, "ciphers", cipherRemoteID, "attachment", attachmentRemoteID]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components?.queryItems = nil
        return components?.url ?? apiURL
    }

    private static func encryptedCipherPayload(for item: BitwardenLocalItemSyncItem, key: BitwardenVaultKey) throws -> [String: Any] {
        var payload: [String: Any] = [
            "type": cipherType(for: item.kind),
            "name": try BitwardenCrypto.encryptString(item.title, key: key),
            "notes": try encryptedOptional(item.notes, key: key),
            "folderId": item.folderID.map { $0 as Any } ?? NSNull(),
            "favorite": false,
            "organizationId": NSNull(),
            "collectionIds": []
        ]

        switch item.kind {
        case .login:
            var login: [String: Any] = [
                "username": try encryptedOptional(item.username, key: key),
                "password": try encryptedOptional(item.password, key: key),
                "totp": try encryptedOptional(item.totpSecret, key: key)
            ]
            if !item.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                login["uris"] = [
                    [
                        "uri": try BitwardenCrypto.encryptString(item.url, key: key),
                        "match": NSNull()
                    ]
                ]
            } else {
                login["uris"] = []
            }
            payload["login"] = login
        case .secureNote:
            payload["secureNote"] = ["type": 0]
        case .card:
            payload["card"] = [
                "cardholderName": try encryptedOptional(item.cardholderName, key: key),
                "number": try encryptedOptional(item.cardNumber, key: key),
                "expMonth": try encryptedOptional(item.cardExpiryMonth, key: key),
                "expYear": try encryptedOptional(item.cardExpiryYear, key: key),
                "code": try encryptedOptional(item.cardCode, key: key),
                "brand": try encryptedOptional(item.cardBrand, key: key)
            ]
        case .identity:
            payload["identity"] = [
                "firstName": try encryptedOptional(item.identityFullName, key: key),
                "passportNumber": try encryptedOptional(item.identityDocumentNumber, key: key),
                "company": try encryptedOptional(item.identityIssuer, key: key),
                "country": try encryptedOptional(item.identityCountry, key: key),
                "email": try encryptedOptional(item.username, key: key)
            ]
        }

        return payload
    }

    private static func encryptedOptional(_ value: String?, key: BitwardenVaultKey) throws -> Any {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return NSNull()
        }
        return try BitwardenCrypto.encryptString(value, key: key)
    }

    private static func cipherType(for kind: BitwardenSyncItemKind) -> Int {
        switch kind {
        case .login:
            1
        case .secureNote:
            2
        case .card:
            3
        case .identity:
            4
        }
    }

    private static func jsonHeaders(accessToken: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "Content-Type": "application/json"
        ]
    }

    private static func revision(from response: BitwardenVaultSyncResponse) -> String? {
        guard !response.body.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else {
            return response.headers["ETag"]
        }
        return jsonString(root, "revisionDate", "RevisionDate") ?? response.headers["ETag"]
    }

    private static func remoteID(from response: BitwardenVaultSyncResponse) -> String? {
        guard !response.body.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else {
            return nil
        }
        return jsonString(root, "id", "Id")
    }

    private static func createdLocalID(for mutation: BitwardenSyncMutation) -> String? {
        switch mutation {
        case .upsertCipher(let item, let remoteID):
            remoteID == nil ? item.localID : nil
        case .upsertSend(let localID, let remoteID, _, _, _, _, _):
            remoteID == nil ? localID : nil
        case .upsertEncryptedSend(let localID, let remoteID, _, _, _, _, _, _, _):
            remoteID == nil ? localID : nil
        case .deleteCipher, .deleteSend:
            nil
        }
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

public final class URLSessionBitwardenVaultSyncTransport: BitwardenVaultSyncTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: BitwardenVaultSyncRequest) async throws -> BitwardenVaultSyncResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        request.headers.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = request.body
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BitwardenSyncProviderError.unsupportedOperation
        }
        var headers: [String: String] = [:]
        httpResponse.allHeaderFields.forEach { key, value in
            guard let key = key as? String else { return }
            headers[key] = "\(value)"
        }
        return BitwardenVaultSyncResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: data
        )
    }
}

public protocol BitwardenSyncProvider: Sendable {
    func pullSnapshot() async throws -> BitwardenSyncSnapshot
    func pushMutations(_ mutations: [BitwardenSyncMutation]) async throws -> BitwardenSyncPushResult
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

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            "Bitwarden 需要先登录。"
        case .unsupportedOperation:
            "Bitwarden 同步当前操作尚未接入。"
        case .unsupportedKDF(let rawValue):
            "Bitwarden KDF \(rawValue) 当前尚未接入。"
        case .twoFactorRequired:
            "Bitwarden 需要两步验证，当前 iOS 登录入口尚未接入验证码。"
        case .serverRejected(let statusCode):
            "Bitwarden 同步失败：服务器返回 \(statusCode)。"
        case .invalidServerURL:
            "Bitwarden 服务器 URL 无效，仅支持 http/https。"
        case .invalidResponse:
            "Bitwarden 同步响应无法解析。"
        }
    }
}

private enum BitwardenVaultSyncSnapshotParser {
    static func parse(_ data: Data, fallbackAccountLabel: String, vaultKey: BitwardenVaultKey? = nil) throws -> BitwardenSyncSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        let profile = dictionary(root, "profile", "Profile")
        let folders = array(root, "folders", "Folders")
        let ciphers = array(root, "ciphers", "Ciphers")
        let sends = array(root, "sends", "Sends")
        let folderNamesByID = Dictionary(uniqueKeysWithValues: folders.compactMap { folder -> (String, String)? in
            guard let id = string(folder, "id", "Id"), !id.isEmpty else { return nil }
            return (id, string(folder, "name", "Name") ?? "")
        })
        let items = ciphers.compactMap { cipher -> BitwardenSyncItem? in
            guard string(cipher, "deletedDate", "DeletedDate") == nil else { return nil }
            guard let id = string(cipher, "id", "Id"), !id.isEmpty else { return nil }
            let type = int(cipher, "type", "Type") ?? 1
            let kind = itemKind(for: type)
            let effectiveKey: BitwardenVaultKey?
            if let vaultKey,
               let itemKey = string(cipher, "key", "Key"),
               !itemKey.isEmpty {
                effectiveKey = try? BitwardenCrypto.decryptSymmetricKey(itemKey, key: vaultKey)
            } else {
                effectiveKey = vaultKey
            }
            let folderID = string(cipher, "folderId", "FolderId")
            let login = dictionary(cipher, "login", "Login")
            let card = dictionary(cipher, "card", "Card")
            let identity = dictionary(cipher, "identity", "Identity")
            let firstURI = array(login, "uris", "Uris").first
            return BitwardenSyncItem(
                remoteID: id,
                kind: kind,
                title: decryptedString(cipher, "name", "Name", key: effectiveKey) ?? "",
                username: decryptedString(login, "username", "Username", key: effectiveKey) ?? identityUsername(cipher, key: effectiveKey),
                url: firstURI.flatMap { decryptedString($0, "uri", "Uri", key: effectiveKey) } ?? "",
                password: decryptedString(login, "password", "Password", key: effectiveKey),
                totpSecret: decryptedString(login, "totp", "Totp", key: effectiveKey),
                notes: decryptedString(cipher, "notes", "Notes", key: effectiveKey),
                folderName: folderID.flatMap { folderNamesByID[$0] },
                collectionNames: [],
                attachmentByteCount: byteCount(array(cipher, "attachments", "Attachments")),
                updatedAt: date(string(cipher, "revisionDate", "RevisionDate")),
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
                identityCountry: decryptedString(identity, "country", "Country", key: effectiveKey) ?? ""
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
            items: items,
            sends: sendItems
        )
    }

    private static func itemKind(for type: Int) -> BitwardenSyncItemKind {
        switch type {
        case 2:
            .secureNote
        case 3:
            .card
        case 4:
            .identity
        default:
            .login
        }
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

private func sanitizedBitwardenTitle(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "未命名" : trimmed
}

private func sanitizedBitwardenText(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalizedBitwardenAccountLabel(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func jsonString(_ json: [String: Any], _ keys: String...) -> String? {
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

private func jsonInt(_ json: [String: Any], _ keys: String...) -> Int? {
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

private extension URL {
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

public protocol CloudFileProvider: Sendable {
    var kind: CloudFileProviderKind { get }

    func connectionState() async throws -> CloudFileConnectionState
    func listFiles() async throws -> [CloudFileItem]
    func downloadFile(id: String) async throws -> CloudFileDownload
    func uploadFile(named fileName: String, data: Data) async throws -> CloudFileWriteReceipt
    func overwriteFile(id: String, data: Data, fileName: String, expectedRevision: String?) async throws -> CloudFileWriteReceipt
}

public extension CloudFileProvider {
    func overwriteFile(id: String, data: Data, fileName: String) async throws -> CloudFileWriteReceipt {
        try await overwriteFile(id: id, data: data, fileName: fileName, expectedRevision: nil)
    }
}

public struct OneDriveCloudFileConfiguration: Sendable, Equatable {
    public let clientID: String
    public let redirectURI: URL
    public let scopes: [String]
    public let graphBaseURL: URL

    public init(
        clientID: String,
        redirectURI: URL,
        scopes: [String] = ["Files.ReadWrite.AppFolder"],
        graphBaseURL: URL = URL(string: "https://graph.microsoft.com/v1.0")!
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.graphBaseURL = graphBaseURL
    }

    public static let monicaProduction = OneDriveCloudFileConfiguration(
        clientID: "2aaf8c2c-b817-4085-9517-586a4a113dfc",
        redirectURI: URL(string: "msauth.com.monica-pass.monica://auth")!
    )

    public var redirectScheme: String {
        redirectURI.scheme ?? ""
    }

    public var redactedSummary: String {
        "OneDrive MSAL \(redirectScheme)"
    }
}

public protocol OneDriveAccessTokenProvider: Sendable {
    func accessToken() async throws -> String
}

public struct EmptyOneDriveAccessTokenProvider: OneDriveAccessTokenProvider {
    public init() {}

    public func accessToken() async throws -> String {
        throw CloudFileProviderError.authenticationRequired(provider: .oneDrive)
    }
}

public struct OneDriveGraphRequest: Sendable, Equatable {
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

public struct OneDriveGraphResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol OneDriveGraphTransport: Sendable {
    func send(_ request: OneDriveGraphRequest) async throws -> OneDriveGraphResponse
}

public struct OneDriveCloudFileProvider: CloudFileProvider {
    public let kind: CloudFileProviderKind = .oneDrive
    public let configuration: OneDriveCloudFileConfiguration
    private let tokenProvider: any OneDriveAccessTokenProvider
    private let graphTransport: any OneDriveGraphTransport

    public init(
        configuration: OneDriveCloudFileConfiguration = .monicaProduction,
        tokenProvider: any OneDriveAccessTokenProvider = EmptyOneDriveAccessTokenProvider(),
        graphTransport: any OneDriveGraphTransport = URLSessionOneDriveGraphTransport()
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.graphTransport = graphTransport
    }

    public func connectionState() async throws -> CloudFileConnectionState {
        do {
            _ = try await tokenProvider.accessToken()
            return .connected(accountLabel: "OneDrive")
        } catch let error as CloudFileProviderError {
            if case .authenticationRequired = error {
                return .disconnected
            }
            throw error
        }
    }

    public func listFiles() async throws -> [CloudFileItem] {
        let response = try await sendGraphRequest(
            method: "GET",
            path: "/me/drive/special/approot/children",
            accept: "application/json"
        )
        try validateSuccess(response, allowedStatusCodes: [200])
        return try OneDriveDriveItemListResponse(response.body)
            .items
            .filter { $0.isFile }
            .map { $0.cloudFileItem }
    }

    public func downloadFile(id: String) async throws -> CloudFileDownload {
        let metadata = try await loadDriveItem(id: id)
        let response = try await sendGraphRequest(
            method: "GET",
            path: "/me/drive/items/\(Self.percentEncodePathComponent(id))/content",
            accept: "application/octet-stream"
        )
        try validateSuccess(response, allowedStatusCodes: [200])
        return CloudFileDownload(
            item: metadata.cloudFileItem,
            data: response.body,
            sha256: response.body.monicaSHA256Hex,
            revision: metadata.revision
        )
    }

    public func uploadFile(named fileName: String, data: Data) async throws -> CloudFileWriteReceipt {
        let response = try await sendGraphRequest(
            method: "PUT",
            path: "/me/drive/special/approot:/\(Self.percentEncodeGraphPath(fileName)):/content",
            headers: ["Content-Type": "application/octet-stream"],
            body: data
        )
        try validateSuccess(response, allowedStatusCodes: [200, 201])
        let item = try OneDriveDriveItem(response.body)
        return writeReceipt(from: item, data: data, fallbackFileName: fileName)
    }

    public func overwriteFile(id: String, data: Data, fileName: String, expectedRevision: String? = nil) async throws -> CloudFileWriteReceipt {
        var headers = ["Content-Type": "application/octet-stream"]
        if let expectedRevision, !expectedRevision.isEmpty {
            headers["If-Match"] = expectedRevision
        }
        let response = try await sendGraphRequest(
            method: "PUT",
            path: "/me/drive/items/\(Self.percentEncodePathComponent(id))/content",
            headers: headers,
            body: data
        )
        if response.statusCode == 412 {
            throw CloudFileProviderError.conflict(provider: kind)
        }
        try validateSuccess(response, allowedStatusCodes: [200, 201])
        let item = try OneDriveDriveItem(response.body)
        return writeReceipt(from: item, data: data, fallbackFileName: fileName)
    }

    private func loadDriveItem(id: String) async throws -> OneDriveDriveItem {
        let response = try await sendGraphRequest(
            method: "GET",
            path: "/me/drive/items/\(Self.percentEncodePathComponent(id))",
            accept: "application/json"
        )
        try validateSuccess(response, allowedStatusCodes: [200])
        return try OneDriveDriveItem(response.body)
    }

    private func sendGraphRequest(
        method: String,
        path: String,
        headers: [String: String] = [:],
        accept: String? = nil,
        body: Data? = nil
    ) async throws -> OneDriveGraphResponse {
        let token = try await tokenProvider.accessToken()
        var requestHeaders = headers
        requestHeaders["Authorization"] = "Bearer \(token)"
        if let accept {
            requestHeaders["Accept"] = accept
        }
        return try await graphTransport.send(
            OneDriveGraphRequest(
                method: method,
                url: configuration.graphBaseURL.appendingGraphPath(path),
                headers: requestHeaders,
                body: body
            )
        )
    }

    private func validateSuccess(
        _ response: OneDriveGraphResponse,
        allowedStatusCodes: Set<Int>
    ) throws {
        if response.statusCode == 401 || response.statusCode == 403 {
            throw CloudFileProviderError.authenticationRequired(provider: kind)
        }
        if response.statusCode == 404 {
            throw CloudFileProviderError.itemNotFound(provider: kind)
        }
        if response.statusCode == 412 {
            throw CloudFileProviderError.conflict(provider: kind)
        }
        guard allowedStatusCodes.contains(response.statusCode) else {
            throw CloudFileProviderError.unsupportedOperation(provider: kind)
        }
    }

    private func writeReceipt(
        from item: OneDriveDriveItem,
        data: Data,
        fallbackFileName: String
    ) -> CloudFileWriteReceipt {
        CloudFileWriteReceipt(
            provider: kind,
            itemID: item.id,
            name: item.name.isEmpty ? fallbackFileName : item.name,
            byteCount: data.count,
            sha256: data.monicaSHA256Hex,
            revision: item.revision
        )
    }

    private static func percentEncodeGraphPath(_ value: String) -> String {
        value
            .split(separator: "/")
            .map { percentEncodePathComponent(String($0)) }
            .joined(separator: "/")
    }

    private static func percentEncodePathComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public final class URLSessionOneDriveGraphTransport: OneDriveGraphTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: OneDriveGraphRequest) async throws -> OneDriveGraphResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        request.headers.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
        }
        var headers: [String: String] = [:]
        httpResponse.allHeaderFields.forEach { key, value in
            guard let key = key as? String else { return }
            headers[key] = "\(value)"
        }
        return OneDriveGraphResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: data
        )
    }
}

private struct OneDriveDriveItemListResponse {
    let items: [OneDriveDriveItem]

    init(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["value"] as? [[String: Any]]
        else {
            throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
        }
        self.items = try values.map(OneDriveDriveItem.init)
    }
}

private struct OneDriveDriveItem {
    let id: String
    let name: String
    let path: String
    let byteCount: Int
    let modifiedAt: Date?
    let revision: String?
    let isFile: Bool

    init(_ data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
        }
        try self.init(json)
    }

    init(_ json: [String: Any]) throws {
        guard let id = json["id"] as? String else {
            throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
        }
        let name = json["name"] as? String ?? ""
        let parentPath = (json["parentReference"] as? [String: Any])?["path"] as? String ?? ""
        self.id = id
        self.name = name
        self.path = Self.combinedPath(parentPath: parentPath, name: name)
        self.byteCount = Self.intValue(json["size"])
        self.modifiedAt = (json["lastModifiedDateTime"] as? String).flatMap(Self.dateValue)
        self.revision = (json["eTag"] as? String) ?? (json["cTag"] as? String)
        self.isFile = json["file"] != nil && json["folder"] == nil
    }

    var cloudFileItem: CloudFileItem {
        CloudFileItem(
            id: id,
            name: name,
            path: path,
            byteCount: byteCount,
            modifiedAt: modifiedAt,
            sha256: nil,
            revision: revision
        )
    }

    private static func combinedPath(parentPath: String, name: String) -> String {
        let trimmedParent = parentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedParent.isEmpty else { return name }
        if trimmedParent.hasSuffix("/") || trimmedParent.hasSuffix(":") {
            return trimmedParent + name
        }
        return trimmedParent + "/" + name
    }

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let string = value as? String, let int = Int(string) {
            return int
        }
        return 0
    }

    private static func dateValue(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

private extension URL {
    func appendingGraphPath(_ path: String) -> URL {
        let base = absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.hasPrefix("/") ? path : "/" + path
        return URL(string: base + suffix) ?? self
    }
}

public struct GoogleDriveCloudFileProvider: CloudFileProvider {
    public let kind: CloudFileProviderKind = .googleDrive

    public init() {}

    public func connectionState() async throws -> CloudFileConnectionState {
        .disconnected
    }

    public func listFiles() async throws -> [CloudFileItem] {
        throw CloudFileProviderError.unsupportedOperation(provider: kind)
    }

    public func downloadFile(id: String) async throws -> CloudFileDownload {
        throw CloudFileProviderError.unsupportedOperation(provider: kind)
    }

    public func uploadFile(named fileName: String, data: Data) async throws -> CloudFileWriteReceipt {
        throw CloudFileProviderError.unsupportedOperation(provider: kind)
    }

    public func overwriteFile(id: String, data: Data, fileName: String, expectedRevision: String? = nil) async throws -> CloudFileWriteReceipt {
        throw CloudFileProviderError.unsupportedOperation(provider: kind)
    }
}

public enum CloudFileProviderError: Error, Sendable, Equatable, LocalizedError {
    case authenticationRequired(provider: CloudFileProviderKind)
    case itemNotFound(provider: CloudFileProviderKind)
    case unsupportedOperation(provider: CloudFileProviderKind)
    case conflict(provider: CloudFileProviderKind)

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired(let provider):
            "\(provider.displayName) 需要先登录。"
        case .itemNotFound(let provider):
            "\(provider.displayName) 未找到远端文件。"
        case .unsupportedOperation(let provider):
            "\(provider.displayName) 当前操作尚未接入。"
        case .conflict(let provider):
            "\(provider.displayName) 远端文件已变化，请重新下载后再写回。"
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

    public init(endpoint: WebDAVEndpoint, transport: any WebDAVTransport = URLSessionWebDAVTransport()) {
        self.endpoint = endpoint
        self.transport = transport
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
}

private extension WebDAVBackupPackage {
    var sidecarFileName: String {
        Self.sidecarFileName(for: fileName)
    }

    static func sidecarFileName(for fileName: String) -> String {
        "\(fileName).sha256"
    }
}

public final class URLSessionWebDAVTransport: WebDAVTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: WebDAVTransportRequest) async throws -> WebDAVTransportResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        request.headers.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: urlRequest)
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
}

public enum WebDAVError: Error, Sendable, Equatable, LocalizedError {
    case unexpectedStatus(operation: String, statusCode: Int)
    case integrityCheckFailed
    case nonHTTPResponse

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let operation, let statusCode):
            return "WebDAV \(operation) 失败，HTTP 状态码 \(statusCode)。"
        case .integrityCheckFailed:
            return "WebDAV 备份完整性校验失败。"
        case .nonHTTPResponse:
            return "WebDAV 服务器返回了非 HTTP 响应。"
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

private func sanitizedCloudFileName(_ value: String) -> String {
    let normalized = value
        .replacingOccurrences(of: "\\", with: "/")
        .split(separator: "/")
        .last
        .map(String.init) ?? value
    let sanitized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.isEmpty ? "未命名文件" : sanitized
}

private extension Data {
    var monicaSHA256Hex: String {
        SHA256.hash(data: self).map { byte in
            String(format: "%02x", byte)
        }.joined()
    }
}
