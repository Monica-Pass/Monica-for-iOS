import CryptoKit
import Foundation

public enum MonicaSyncBaseline {
    public static let firstBackupProvider = "WebDAV"
}

public enum BitwardenSyncItemKind: String, Sendable, Equatable, Hashable {
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

    public init(
        acceptedMutationCount: Int,
        conflicts: [BitwardenSyncConflict] = [],
        revision: String = ""
    ) {
        self.acceptedMutationCount = acceptedMutationCount
        self.conflicts = conflicts
        self.revision = revision
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

public protocol BitwardenVaultSyncTransport: Sendable {
    func send(_ request: BitwardenVaultSyncRequest) async throws -> BitwardenVaultSyncResponse
}

public struct BitwardenVaultSyncProvider: BitwardenSyncProvider {
    private let sessionStore: any BitwardenAuthenticationSessionStore
    private let accessTokenProvider: RefreshingBitwardenAccessTokenProvider
    private let vaultTransport: any BitwardenVaultSyncTransport

    public init(
        sessionStore: any BitwardenAuthenticationSessionStore,
        identityTransport: any BitwardenIdentityTokenTransport = URLSessionBitwardenIdentityTokenTransport(),
        vaultTransport: any BitwardenVaultSyncTransport = URLSessionBitwardenVaultSyncTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sessionStore = sessionStore
        self.accessTokenProvider = RefreshingBitwardenAccessTokenProvider(
            sessionStore: sessionStore,
            identityTransport: identityTransport,
            now: now
        )
        self.vaultTransport = vaultTransport
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
        return try BitwardenVaultSyncSnapshotParser.parse(response.body, fallbackAccountLabel: session.accountLabel)
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
        var acceptedMutationCount = 0
        var latestRevision = ""
        for mutation in mutations {
            let response = try await vaultTransport.send(
                try Self.request(
                    for: mutation,
                    apiURL: session.apiURL,
                    accessToken: accessToken
                )
            )
            if response.statusCode == 401 || response.statusCode == 403 {
                throw BitwardenSyncProviderError.authenticationRequired
            }
            if case .deleteSend = mutation, response.statusCode == 404 {
                acceptedMutationCount += 1
                continue
            }
            guard (200...299).contains(response.statusCode) else {
                throw BitwardenSyncProviderError.serverRejected(statusCode: response.statusCode)
            }
            acceptedMutationCount += 1
            latestRevision = Self.revision(from: response) ?? latestRevision
        }
        return BitwardenSyncPushResult(
            acceptedMutationCount: acceptedMutationCount,
            conflicts: [],
            revision: latestRevision
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
        accessToken: String
    ) throws -> BitwardenVaultSyncRequest {
        switch mutation {
        case .upsertSend:
            throw BitwardenSyncProviderError.unsupportedOperation
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
    case serverRejected(statusCode: Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            "Bitwarden 需要先登录。"
        case .unsupportedOperation:
            "Bitwarden 同步当前操作尚未接入。"
        case .serverRejected(let statusCode):
            "Bitwarden 同步失败：服务器返回 \(statusCode)。"
        case .invalidResponse:
            "Bitwarden 同步响应无法解析。"
        }
    }
}

private enum BitwardenVaultSyncSnapshotParser {
    static func parse(_ data: Data, fallbackAccountLabel: String) throws -> BitwardenSyncSnapshot {
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
            let folderID = string(cipher, "folderId", "FolderId")
            let login = dictionary(cipher, "login", "Login")
            let card = dictionary(cipher, "card", "Card")
            let identity = dictionary(cipher, "identity", "Identity")
            let firstURI = array(login, "uris", "Uris").first
            return BitwardenSyncItem(
                remoteID: id,
                kind: kind,
                title: string(cipher, "name", "Name") ?? "",
                username: string(login, "username", "Username") ?? identityUsername(cipher),
                url: firstURI.flatMap { string($0, "uri", "Uri") } ?? "",
                password: string(login, "password", "Password"),
                totpSecret: string(login, "totp", "Totp"),
                notes: string(cipher, "notes", "Notes"),
                folderName: folderID.flatMap { folderNamesByID[$0] },
                collectionNames: [],
                attachmentByteCount: byteCount(array(cipher, "attachments", "Attachments")),
                updatedAt: date(string(cipher, "revisionDate", "RevisionDate")),
                cardholderName: string(card, "cardholderName", "CardholderName") ?? "",
                cardNumber: string(card, "number", "Number") ?? "",
                cardExpiryMonth: string(card, "expMonth", "ExpMonth") ?? "",
                cardExpiryYear: string(card, "expYear", "ExpYear") ?? "",
                cardCode: string(card, "code", "Code") ?? "",
                cardBrand: string(card, "brand", "Brand") ?? "",
                identityFullName: identityFullName(identity),
                identityDocumentNumber: string(identity, "passportNumber", "PassportNumber")
                    ?? string(identity, "licenseNumber", "LicenseNumber")
                    ?? "",
                identityIssuer: string(identity, "company", "Company") ?? "",
                identityCountry: string(identity, "country", "Country") ?? ""
            )
        }
        let sendItems = sends.compactMap { send -> BitwardenSendSyncItem? in
            guard let id = string(send, "id", "Id"), !id.isEmpty else { return nil }
            let text = dictionary(send, "text", "Text")
            let file = dictionary(send, "file", "File")
            let fileName = string(file, "fileName", "FileName")
            return BitwardenSendSyncItem(
                remoteID: id,
                title: string(send, "name", "Name") ?? fileName ?? "",
                body: string(text, "text", "Text") ?? fileName ?? "",
                notes: string(send, "notes", "Notes"),
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

    private static func identityUsername(_ cipher: [String: Any]) -> String {
        let identity = dictionary(cipher, "identity", "Identity")
        return string(identity, "username", "Username")
            ?? string(identity, "email", "Email")
            ?? ""
    }

    private static func identityFullName(_ identity: [String: Any]) -> String {
        [
            string(identity, "title", "Title") ?? "",
            string(identity, "firstName", "FirstName") ?? "",
            string(identity, "middleName", "MiddleName") ?? "",
            string(identity, "lastName", "LastName") ?? ""
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
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
