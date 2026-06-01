import CryptoKit
import Foundation
import Security

public struct MonicaCoreInfo: Sendable, Equatable {
    public let minimumIOSVersion: String
    public let storageStrategy: String

    public init(
        minimumIOSVersion: String = "17.0",
        storageStrategy: String = "MDBX 优先"
    ) {
        self.minimumIOSVersion = minimumIOSVersion
        self.storageStrategy = storageStrategy
    }
}

public struct PasswordGeneratorPolicy: Sendable, Equatable {
    public static let defaultSymbols = "!@#$%^&*()-_=+[]{}:,.?"
    public static let defaultSymbolCharacterSet = CharacterSet(charactersIn: defaultSymbols)

    public let length: Int
    public let includeUppercase: Bool
    public let includeLowercase: Bool
    public let includeDigits: Bool
    public let includeSymbols: Bool

    public init(
        length: Int = 20,
        includeUppercase: Bool = true,
        includeLowercase: Bool = true,
        includeDigits: Bool = true,
        includeSymbols: Bool = true
    ) {
        self.length = length
        self.includeUppercase = includeUppercase
        self.includeLowercase = includeLowercase
        self.includeDigits = includeDigits
        self.includeSymbols = includeSymbols
    }

    var enabledCharacterPools: [[Character]] {
        var pools: [[Character]] = []
        if includeUppercase {
            pools.append(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        }
        if includeLowercase {
            pools.append(Array("abcdefghijklmnopqrstuvwxyz"))
        }
        if includeDigits {
            pools.append(Array("0123456789"))
        }
        if includeSymbols {
            pools.append(Array(Self.defaultSymbols))
        }
        return pools
    }
}

public enum PasswordGeneratorError: Error, Sendable, Equatable {
    case invalidLength
    case emptyCharacterSet
    case randomFailure
}

public enum PasswordGenerator {
    public static func generate(
        policy: PasswordGeneratorPolicy = PasswordGeneratorPolicy()
    ) throws -> String {
        try generate(policy: policy, randomBytes: secureRandomBytes)
    }

    public static func generate(
        policy: PasswordGeneratorPolicy,
        randomBytes: (Int) throws -> [UInt8]
    ) throws -> String {
        let pools = policy.enabledCharacterPools
        guard !pools.isEmpty else {
            throw PasswordGeneratorError.emptyCharacterSet
        }
        guard policy.length >= 8, policy.length >= pools.count else {
            throw PasswordGeneratorError.invalidLength
        }

        let combinedPool = pools.flatMap { $0 }
        var password: [Character] = []

        for pool in pools {
            let index = try randomIndex(upperBound: pool.count, randomBytes: randomBytes)
            password.append(pool[index])
        }

        while password.count < policy.length {
            let index = try randomIndex(upperBound: combinedPool.count, randomBytes: randomBytes)
            password.append(combinedPool[index])
        }

        try shuffle(&password, randomBytes: randomBytes)
        return String(password)
    }

    private static func secureRandomBytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw PasswordGeneratorError.randomFailure
        }
        return bytes
    }

    private static func randomIndex(
        upperBound: Int,
        randomBytes: (Int) throws -> [UInt8]
    ) throws -> Int {
        guard upperBound > 0, upperBound <= Int(UInt8.max) else {
            throw PasswordGeneratorError.emptyCharacterSet
        }

        let limit = Int(UInt8.max) - (Int(UInt8.max) % upperBound)
        while true {
            guard let byte = try randomBytes(1).first else {
                throw PasswordGeneratorError.randomFailure
            }
            let value = Int(byte)
            if value < limit {
                return value % upperBound
            }
        }
    }

    private static func shuffle(
        _ characters: inout [Character],
        randomBytes: (Int) throws -> [UInt8]
    ) throws {
        guard characters.count > 1 else {
            return
        }

        for index in characters.indices.dropLast() {
            let offset = try randomIndex(
                upperBound: characters.count - index,
                randomBytes: randomBytes
            )
            characters.swapAt(index, index + offset)
        }
    }
}

public enum SecretGeneratorPolicy: Sendable, Equatable {
    case password(PasswordGeneratorPolicy)
    case pin(length: Int)
    case passphrase(wordCount: Int, separator: String, wordList: [String])
    case apiToken(prefix: String, byteCount: Int)
}

public enum SecretGenerator {
    public static let defaultPassphraseWords = [
        "amber",
        "anchor",
        "brisk",
        "cedar",
        "coral",
        "delta",
        "ember",
        "fjord",
        "granite",
        "harbor",
        "indigo",
        "jasmine",
        "keystone",
        "linen",
        "magnet",
        "nebula",
        "onyx",
        "prairie",
        "quartz",
        "ripple",
        "signal",
        "tundra",
        "velvet",
        "willow"
    ]

    public static func generate(policy: SecretGeneratorPolicy) throws -> String {
        try generate(policy: policy, randomBytes: secureRandomBytes)
    }

    public static func generate(
        policy: SecretGeneratorPolicy,
        randomBytes: (Int) throws -> [UInt8]
    ) throws -> String {
        switch policy {
        case .password(let passwordPolicy):
            return try PasswordGenerator.generate(policy: passwordPolicy, randomBytes: randomBytes)
        case .pin(let length):
            return try generatePIN(length: length, randomBytes: randomBytes)
        case .passphrase(let wordCount, let separator, let wordList):
            return try generatePassphrase(
                wordCount: wordCount,
                separator: separator,
                wordList: wordList,
                randomBytes: randomBytes
            )
        case .apiToken(let prefix, let byteCount):
            return try generateAPIToken(prefix: prefix, byteCount: byteCount, randomBytes: randomBytes)
        }
    }

    private static func generatePIN(
        length: Int,
        randomBytes: (Int) throws -> [UInt8]
    ) throws -> String {
        guard (4...32).contains(length) else {
            throw PasswordGeneratorError.invalidLength
        }

        let digits = Array("0123456789")
        var value: [Character] = []
        value.reserveCapacity(length)
        while value.count < length {
            let index = try randomIndex(upperBound: digits.count, randomBytes: randomBytes)
            value.append(digits[index])
        }
        return String(value)
    }

    private static func generatePassphrase(
        wordCount: Int,
        separator: String,
        wordList: [String],
        randomBytes: (Int) throws -> [UInt8]
    ) throws -> String {
        guard wordCount >= 3 else {
            throw PasswordGeneratorError.invalidLength
        }
        guard !wordList.isEmpty else {
            throw PasswordGeneratorError.emptyCharacterSet
        }

        var words: [String] = []
        words.reserveCapacity(wordCount)
        while words.count < wordCount {
            let index = try randomIndex(upperBound: wordList.count, randomBytes: randomBytes)
            words.append(wordList[index].lowercased())
        }
        return words.joined(separator: separator)
    }

    private static func generateAPIToken(
        prefix: String,
        byteCount: Int,
        randomBytes: (Int) throws -> [UInt8]
    ) throws -> String {
        guard byteCount >= 16 else {
            throw PasswordGeneratorError.invalidLength
        }

        let token = Data(try randomBytes(byteCount))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let normalizedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedPrefix.isEmpty {
            return token
        }
        return "\(normalizedPrefix)_\(token)"
    }

    private static func secureRandomBytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw PasswordGeneratorError.randomFailure
        }
        return bytes
    }

    private static func randomIndex(
        upperBound: Int,
        randomBytes: (Int) throws -> [UInt8]
    ) throws -> Int {
        guard upperBound > 0, upperBound <= Int(UInt8.max) else {
            throw PasswordGeneratorError.emptyCharacterSet
        }

        let limit = Int(UInt8.max) - (Int(UInt8.max) % upperBound)
        while true {
            guard let byte = try randomBytes(1).first else {
                throw PasswordGeneratorError.randomFailure
            }
            let value = Int(byte)
            if value < limit {
                return value % upperBound
            }
        }
    }
}

public enum TotpAlgorithm: String, Sendable, Equatable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
}

public enum TotpError: Error, Sendable, Equatable {
    case invalidSecret
    case invalidDigits
    case invalidPeriod
    case invalidAlgorithm
    case invalidURI
}

public struct TotpImportDraft: Sendable, Equatable {
    public let title: String
    public let secret: String
    public let issuer: String
    public let accountName: String
    public let period: Int
    public let digits: Int
    public let algorithm: TotpAlgorithm

    public init(
        title: String,
        secret: String,
        issuer: String,
        accountName: String,
        period: Int,
        digits: Int,
        algorithm: TotpAlgorithm
    ) {
        self.title = title
        self.secret = secret
        self.issuer = issuer
        self.accountName = accountName
        self.period = period
        self.digits = digits
        self.algorithm = algorithm
    }
}

public enum TotpURIParser {
    public static func parse(_ value: String) throws -> TotpImportDraft {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "otpauth",
              components.host?.lowercased() == "totp" else {
            throw TotpError.invalidURI
        }

        let query = queryItems(from: components)
        let secret = try normalizedSecret(query["secret"])
        _ = try Base32.decode(secret)

        let issuerFromQuery = query["issuer"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = normalizedLabel(from: components.path)
        let labelParts = label.split(separator: ":", maxSplits: 1).map(String.init)
        let issuerFromLabel = labelParts.count == 2 ? labelParts[0] : ""
        let accountName = labelParts.count == 2 ? labelParts[1] : label
        let issuer = issuerFromQuery.isEmpty ? issuerFromLabel : issuerFromQuery
        let title = issuer.isEmpty ? accountName : issuer

        let period = try normalizedInteger(
            query["period"],
            defaultValue: 30,
            error: .invalidPeriod
        )
        guard period > 0 else {
            throw TotpError.invalidPeriod
        }

        let digits = try normalizedInteger(
            query["digits"],
            defaultValue: 6,
            error: .invalidDigits
        )
        guard (6...8).contains(digits) else {
            throw TotpError.invalidDigits
        }

        let algorithm = try normalizedAlgorithm(query["algorithm"])

        return TotpImportDraft(
            title: title,
            secret: secret,
            issuer: issuer,
            accountName: accountName,
            period: period,
            digits: digits,
            algorithm: algorithm
        )
    }

    private static func queryItems(from components: URLComponents) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name.lowercased(), $0) }
            }
        )
    }

    private static func normalizedSecret(_ value: String?) throws -> String {
        let normalized = (value ?? "")
            .uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw TotpError.invalidSecret
        }
        return normalized
    }

    private static func normalizedLabel(from path: String) -> String {
        let rawLabel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return rawLabel.removingPercentEncoding ?? rawLabel
    }

    private static func normalizedInteger(
        _ value: String?,
        defaultValue: Int,
        error: TotpError
    ) throws -> Int {
        guard let value, !value.isEmpty else {
            return defaultValue
        }
        guard let integer = Int(value) else {
            throw error
        }
        return integer
    }

    private static func normalizedAlgorithm(_ value: String?) throws -> TotpAlgorithm {
        let normalized = (value ?? TotpAlgorithm.sha1.rawValue).uppercased()
        guard let algorithm = TotpAlgorithm(rawValue: normalized) else {
            throw TotpError.invalidAlgorithm
        }
        return algorithm
    }
}

public enum TotpGenerator {
    public static func generate(
        secret: String,
        algorithm: TotpAlgorithm,
        digits: Int,
        period: Int,
        timestamp: TimeInterval
    ) throws -> String {
        guard (6...8).contains(digits) else {
            throw TotpError.invalidDigits
        }
        guard period > 0 else {
            throw TotpError.invalidPeriod
        }

        let secretData = try Base32.decode(secret)
        let counter = UInt64(timestamp / Double(period))
        return hotp(
            secret: secretData,
            counter: counter,
            algorithm: algorithm,
            digits: digits
        )
    }

    private static func hotp(
        secret: Data,
        counter: UInt64,
        algorithm: TotpAlgorithm,
        digits: Int
    ) -> String {
        var counter = counter.bigEndian
        let counterData = Data(bytes: &counter, count: MemoryLayout<UInt64>.size)
        let key = SymmetricKey(data: secret)
        let hmac: Data

        switch algorithm {
        case .sha1:
            hmac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key))
        case .sha256:
            hmac = Data(HMAC<SHA256>.authenticationCode(for: counterData, using: key))
        case .sha512:
            hmac = Data(HMAC<SHA512>.authenticationCode(for: counterData, using: key))
        }

        let offset = Int(hmac[hmac.count - 1] & 0x0f)
        let binaryCode = (UInt32(hmac[offset] & 0x7f) << 24)
            | (UInt32(hmac[offset + 1]) << 16)
            | (UInt32(hmac[offset + 2]) << 8)
            | UInt32(hmac[offset + 3])
        let divisor = UInt32(pow(10.0, Double(digits)))
        let otp = binaryCode % divisor
        return String(format: "%0*u", digits, otp)
    }
}

private enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func decode(_ value: String) throws -> Data {
        let normalized = value
            .uppercased()
            .filter { !$0.isWhitespace && $0 != "=" }

        guard !normalized.isEmpty else {
            throw TotpError.invalidSecret
        }

        var buffer = 0
        var bitsLeft = 0
        var bytes: [UInt8] = []

        for character in normalized {
            guard let index = alphabet.firstIndex(of: character) else {
                throw TotpError.invalidSecret
            }

            buffer = (buffer << 5) | index
            bitsLeft += 5

            if bitsLeft >= 8 {
                bitsLeft -= 8
                bytes.append(UInt8((buffer >> bitsLeft) & 0xff))
                buffer &= (1 << bitsLeft) - 1
            }
        }

        guard !bytes.isEmpty else {
            throw TotpError.invalidSecret
        }

        return Data(bytes)
    }
}
