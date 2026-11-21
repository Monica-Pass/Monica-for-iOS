// MARK: - Bitwarden 加密原语（CipherString / KDF / 对称加解密）

import CommonCrypto
import CryptoKit
import Foundation
import Security
import argon2

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
