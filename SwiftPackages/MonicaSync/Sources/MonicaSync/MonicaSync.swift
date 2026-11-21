import CommonCrypto
import CryptoKit
import Foundation
import Security
import argon2

public enum MonicaSyncBaseline {
    public static let firstBackupProvider = "WebDAV"
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

struct BitwardenCipherString {
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

struct BitwardenServerURLs {
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

struct BitwardenPreloginPayload {
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

struct BitwardenTokenPayload {
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

func normalizedBitwardenAccountLabel(_ value: String) -> String {
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

extension Data {
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

func sanitizedCloudFileName(_ value: String) -> String {
    let normalized = value
        .replacingOccurrences(of: "\\", with: "/")
        .split(separator: "/")
        .last
        .map(String.init) ?? value
    let sanitized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.isEmpty ? "未命名文件" : sanitized
}

extension Data {
    var monicaSHA256Hex: String {
        SHA256.hash(data: self).map { byte in
            String(format: "%02x", byte)
        }.joined()
    }
}
