// MARK: - Bitwarden 令牌刷新（access token 刷新与 identity 传输）

import Foundation

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
