import CryptoKit
import Foundation
import Security
import argon2

public enum SecurityQuestionCredentialError: Error, Sendable, Equatable, LocalizedError {
    case emptyAnswer
    case invalidSaltLength(expected: Int, actual: Int)
    case invalidParameters(String)
    case corruptedStoredRecord
    case legacyStoreReadOnly
    case randomnessUnavailable(Int32)
    case keyDerivationFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .emptyAnswer:
            return "密保答案不能为空。"
        case .invalidSaltLength(let expected, let actual):
            return "密保盐长度必须为 \(expected) 字节，当前为 \(actual) 字节。"
        case .invalidParameters(let reason):
            return "密保参数无效：\(reason)"
        case .corruptedStoredRecord:
            return "密保记录已损坏，无法读取。可重新设置密保问题。"
        case .legacyStoreReadOnly:
            return "旧版密保记录只能读取，不能写入。"
        case .randomnessUnavailable(let status):
            return "无法生成随机盐（状态 \(status)）。"
        case .keyDerivationFailed(let status):
            return "密保答案派生失败（状态 \(status)）。"
        }
    }
}

/// 密保答案规范化规则（#59）。
///
/// 新记录统一使用 `normalized(_:)`：Unicode NFC 规范化 → 去除首尾空白 → 连续空白折叠为单个空格 → 大小写折叠。
/// 旧记录（无盐 SHA-256）必须继续使用 `legacyNormalized(_:)` 校验，否则已设置密保的用户升级后将无法作答。
public enum SecurityQuestionAnswerNormalizer {
    public static func normalized(_ answer: String) -> String {
        let precomposed = answer.precomposedStringWithCanonicalMapping
        let collapsed = precomposed
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.lowercased()
    }

    public static func legacyNormalized(_ answer: String) -> String {
        answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum SecurityQuestionAnswerAlgorithm: String, Codable, Sendable, Equatable, CaseIterable {
    case argon2id
    case pbkdf2SHA256

    public var displayName: String {
        switch self {
        case .argon2id:
            return "Argon2id"
        case .pbkdf2SHA256:
            return "PBKDF2-SHA256"
        }
    }
}

public struct SecurityQuestionKDFParameters: Codable, Sendable, Equatable {
    public static let defaultSaltByteCount = 16
    public static let minimumSaltByteCount = 16
    public static let defaultArgon2TimeCost: UInt32 = 3
    public static let defaultArgon2MemoryKiB: UInt32 = 32 * 1024
    public static let minimumArgon2MemoryKiB: UInt32 = 1024
    public static let maximumArgon2MemoryKiB: UInt32 = 256 * 1024
    public static let defaultArgon2Parallelism: UInt32 = 1

    public static let `default`: SecurityQuestionKDFParameters = .argon2id()

    public let saltByteCount: Int
    public let timeCost: UInt32?
    public let memoryKiB: UInt32?
    public let parallelism: UInt32?
    public let iterations: UInt32?

    public init(
        saltByteCount: Int = SecurityQuestionKDFParameters.defaultSaltByteCount,
        timeCost: UInt32? = nil,
        memoryKiB: UInt32? = nil,
        parallelism: UInt32? = nil,
        iterations: UInt32? = nil
    ) {
        self.saltByteCount = saltByteCount
        self.timeCost = timeCost
        self.memoryKiB = memoryKiB
        self.parallelism = parallelism
        self.iterations = iterations
    }

    public static func argon2id(
        timeCost: UInt32 = SecurityQuestionKDFParameters.defaultArgon2TimeCost,
        memoryKiB: UInt32 = SecurityQuestionKDFParameters.defaultArgon2MemoryKiB,
        parallelism: UInt32 = SecurityQuestionKDFParameters.defaultArgon2Parallelism,
        saltByteCount: Int = SecurityQuestionKDFParameters.defaultSaltByteCount
    ) -> SecurityQuestionKDFParameters {
        SecurityQuestionKDFParameters(
            saltByteCount: saltByteCount,
            timeCost: timeCost,
            memoryKiB: memoryKiB,
            parallelism: parallelism,
            iterations: nil
        )
    }

    public static func pbkdf2SHA256(
        iterations: UInt32,
        saltByteCount: Int = SecurityQuestionKDFParameters.defaultSaltByteCount
    ) -> SecurityQuestionKDFParameters {
        SecurityQuestionKDFParameters(
            saltByteCount: saltByteCount,
            timeCost: nil,
            memoryKiB: nil,
            parallelism: nil,
            iterations: iterations
        )
    }

    public var algorithm: SecurityQuestionAnswerAlgorithm {
        if timeCost != nil || memoryKiB != nil || parallelism != nil {
            return .argon2id
        }
        return .pbkdf2SHA256
    }

    public var summary: String {
        switch algorithm {
        case .argon2id:
            return "Argon2id · \(memoryKiB ?? 0) KiB · t=\(timeCost ?? 0) · p=\(parallelism ?? 0)"
        case .pbkdf2SHA256:
            return "PBKDF2-SHA256 · \(iterations ?? 0) 次"
        }
    }

    func validationFailure() -> String? {
        guard saltByteCount >= Self.minimumSaltByteCount else {
            return "盐长度不足 \(Self.minimumSaltByteCount) 字节。"
        }
        switch algorithm {
        case .argon2id:
            guard iterations == nil else {
                return "Argon2id 参数不应包含 PBKDF2 迭代次数。"
            }
            guard let timeCost, (1...64).contains(timeCost) else {
                return "Argon2id 时间成本超出允许范围（1-64）。"
            }
            guard let memoryKiB,
                  (Self.minimumArgon2MemoryKiB...Self.maximumArgon2MemoryKiB).contains(memoryKiB) else {
                return "Argon2id 内存成本超出允许范围（1-256 MiB）。"
            }
            guard let parallelism, (1...16).contains(parallelism) else {
                return "Argon2id 并行度超出允许范围（1-16）。"
            }
        case .pbkdf2SHA256:
            guard timeCost == nil, memoryKiB == nil, parallelism == nil else {
                return "PBKDF2 参数不应包含 Argon2id 字段。"
            }
            guard let iterations, (1...1_000_000).contains(iterations) else {
                return "PBKDF2 迭代次数超出允许范围（1-1000000）。"
            }
        }
        return nil
    }
}

public struct SecurityQuestionAnswerRecord: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let digestByteCount = 32

    public let schemaVersion: Int
    public let algorithm: SecurityQuestionAnswerAlgorithm
    public let parameters: SecurityQuestionKDFParameters
    public let salt: Data
    public let digest: Data
    public let createdAt: Date

    public init(
        schemaVersion: Int = SecurityQuestionAnswerRecord.currentSchemaVersion,
        algorithm: SecurityQuestionAnswerAlgorithm,
        parameters: SecurityQuestionKDFParameters,
        salt: Data,
        digest: Data,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.parameters = parameters
        self.salt = salt
        self.digest = digest
        self.createdAt = createdAt
    }

    func validationFailure() -> String? {
        guard schemaVersion == Self.currentSchemaVersion else {
            return "不支持的密保记录版本 \(schemaVersion)。"
        }
        if let failure = parameters.validationFailure() {
            return failure
        }
        guard algorithm == parameters.algorithm else {
            return "密保记录的算法与参数不一致。"
        }
        guard salt.count == parameters.saltByteCount else {
            return "密保记录的盐长度为 \(salt.count) 字节，与参数不一致。"
        }
        guard digest.count == Self.digestByteCount else {
            return "密保记录的验证值长度为 \(digest.count) 字节，应为 \(Self.digestByteCount) 字节。"
        }
        return nil
    }
}

public enum SecurityQuestionAnswerCredential: Sendable, Codable, Equatable {
    case legacyUnsaltedSHA256(hexDigest: String)
    case kdf(SecurityQuestionAnswerRecord)

    private enum CodingKeys: String, CodingKey {
        case kind
        case hexDigest
        case record
    }

    private enum Kind: String, Codable {
        case legacyUnsaltedSHA256
        case kdf
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .legacyUnsaltedSHA256:
            self = .legacyUnsaltedSHA256(hexDigest: try container.decode(String.self, forKey: .hexDigest))
        case .kdf:
            self = .kdf(try container.decode(SecurityQuestionAnswerRecord.self, forKey: .record))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .legacyUnsaltedSHA256(let hexDigest):
            try container.encode(Kind.legacyUnsaltedSHA256, forKey: .kind)
            try container.encode(hexDigest, forKey: .hexDigest)
        case .kdf(let record):
            try container.encode(Kind.kdf, forKey: .kind)
            try container.encode(record, forKey: .record)
        }
    }

    public var isLegacy: Bool {
        if case .legacyUnsaltedSHA256 = self {
            return true
        }
        return false
    }

    public var algorithm: SecurityQuestionAnswerAlgorithm? {
        if case .kdf(let record) = self {
            return record.algorithm
        }
        return nil
    }
}

public enum SecurityQuestionAnswerVerdict: Sendable, Equatable {
    case matched(needsUpgrade: Bool)
    case legacyMatched
    case mismatched
    case invalidRecord(String)

    public var isMatch: Bool {
        switch self {
        case .matched, .legacyMatched:
            return true
        case .mismatched, .invalidRecord:
            return false
        }
    }

    public var requiresRehash: Bool {
        switch self {
        case .legacyMatched:
            return true
        case .matched(let needsUpgrade):
            return needsUpgrade
        case .mismatched, .invalidRecord:
            return false
        }
    }

    public var invalidRecordReason: String? {
        if case .invalidRecord(let reason) = self {
            return reason
        }
        return nil
    }
}

public struct SecurityQuestionAnswerHasher: Sendable {
    public let parameters: SecurityQuestionKDFParameters
    public let schemaVersion: Int
    public let saltGenerator: @Sendable (Int) throws -> Data
    public let now: @Sendable () -> Date

    public init(
        parameters: SecurityQuestionKDFParameters = .default,
        schemaVersion: Int = SecurityQuestionAnswerRecord.currentSchemaVersion,
        saltGenerator: @escaping @Sendable (Int) throws -> Data = { byteCount in
            try SecurityQuestionAnswerHasher.secureRandomSalt(byteCount: byteCount)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.parameters = parameters
        self.schemaVersion = schemaVersion
        self.saltGenerator = saltGenerator
        self.now = now
    }

    public func validateParameters() throws {
        if let failure = parameters.validationFailure() {
            throw SecurityQuestionCredentialError.invalidParameters(failure)
        }
    }

    public func makeRecord(for answer: String) throws -> SecurityQuestionAnswerRecord {
        try validateParameters()
        let normalized = SecurityQuestionAnswerNormalizer.normalized(answer)
        guard !normalized.isEmpty else {
            throw SecurityQuestionCredentialError.emptyAnswer
        }
        let salt = try saltGenerator(parameters.saltByteCount)
        guard salt.count == parameters.saltByteCount else {
            throw SecurityQuestionCredentialError.invalidSaltLength(
                expected: parameters.saltByteCount,
                actual: salt.count
            )
        }
        let digest = try Self.deriveDigest(
            normalizedAnswer: normalized,
            salt: salt,
            algorithm: parameters.algorithm,
            parameters: parameters
        )
        let record = SecurityQuestionAnswerRecord(
            schemaVersion: schemaVersion,
            algorithm: parameters.algorithm,
            parameters: parameters,
            salt: salt,
            digest: digest,
            createdAt: now()
        )
        if let failure = record.validationFailure() {
            throw SecurityQuestionCredentialError.invalidParameters(failure)
        }
        return record
    }

    public func makeCredential(for answer: String) throws -> SecurityQuestionAnswerCredential {
        .kdf(try makeRecord(for: answer))
    }

    public func digest(for answer: String, salt: Data) throws -> Data {
        try Self.deriveDigest(
            normalizedAnswer: SecurityQuestionAnswerNormalizer.normalized(answer),
            salt: salt,
            algorithm: parameters.algorithm,
            parameters: parameters
        )
    }

    public func needsUpgrade(_ record: SecurityQuestionAnswerRecord) -> Bool {
        record.schemaVersion != schemaVersion
            || record.algorithm != parameters.algorithm
            || record.parameters != parameters
    }

    public static func secureRandomSalt(
        byteCount: Int = SecurityQuestionKDFParameters.defaultSaltByteCount
    ) throws -> Data {
        guard byteCount > 0 else {
            throw SecurityQuestionCredentialError.invalidSaltLength(expected: 1, actual: byteCount)
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            throw SecurityQuestionCredentialError.randomnessUnavailable(Int32(status))
        }
        return Data(bytes)
    }

    public static func deriveDigest(
        normalizedAnswer: String,
        salt: Data,
        algorithm: SecurityQuestionAnswerAlgorithm,
        parameters: SecurityQuestionKDFParameters
    ) throws -> Data {
        guard !normalizedAnswer.isEmpty else {
            throw SecurityQuestionCredentialError.emptyAnswer
        }
        let password = Data(normalizedAnswer.utf8)
        switch algorithm {
        case .argon2id:
            guard let timeCost = parameters.timeCost,
                  let memoryKiB = parameters.memoryKiB,
                  let parallelism = parameters.parallelism
            else {
                throw SecurityQuestionCredentialError.invalidParameters("缺少 Argon2id 参数。")
            }
            return try argon2idDigest(
                password: password,
                salt: salt,
                timeCost: timeCost,
                memoryKiB: memoryKiB,
                parallelism: parallelism
            )
        case .pbkdf2SHA256:
            guard let iterations = parameters.iterations else {
                throw SecurityQuestionCredentialError.invalidParameters("缺少 PBKDF2 迭代次数。")
            }
            return try pbkdf2SHA256(
                password: password,
                salt: salt,
                iterations: iterations,
                outputByteCount: SecurityQuestionAnswerRecord.digestByteCount
            )
        }
    }

    public static func argon2idDigest(
        password: Data,
        salt: Data,
        timeCost: UInt32,
        memoryKiB: UInt32,
        parallelism: UInt32
    ) throws -> Data {
        var passwordBytes = password
        var saltBytes = salt
        var output = Data(repeating: 0, count: SecurityQuestionAnswerRecord.digestByteCount)
        let outputLength = output.count
        let status = output.withUnsafeMutableBytes { outputBuffer in
            passwordBytes.withUnsafeMutableBytes { passwordBuffer in
                saltBytes.withUnsafeMutableBytes { saltBuffer in
                    argon2_hash(
                        timeCost,
                        memoryKiB,
                        parallelism,
                        passwordBuffer.baseAddress,
                        passwordBuffer.count,
                        saltBuffer.baseAddress,
                        saltBuffer.count,
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
            throw SecurityQuestionCredentialError.keyDerivationFailed(status)
        }
        return output
    }

    public static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        iterations: UInt32,
        outputByteCount: Int
    ) throws -> Data {
        guard iterations > 0 else {
            throw SecurityQuestionCredentialError.invalidParameters("PBKDF2 迭代次数必须大于零。")
        }
        guard outputByteCount > 0, outputByteCount <= 64 * 1024 else {
            throw SecurityQuestionCredentialError.invalidParameters("PBKDF2 输出长度超出允许范围。")
        }
        let key = SymmetricKey(data: password)
        var derived = Data()
        derived.reserveCapacity(outputByteCount)
        var blockIndex: UInt32 = 1
        while derived.count < outputByteCount {
            var blockSalt = salt
            withUnsafeBytes(of: blockIndex.bigEndian) { blockSalt.append(contentsOf: $0) }
            var u = Data(HMAC<SHA256>.authenticationCode(for: blockSalt, using: key))
            var t = u
            var iteration: UInt32 = 1
            while iteration < iterations {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                for index in t.indices {
                    t[index] ^= u[index]
                }
                iteration += 1
            }
            derived.append(t)
            blockIndex &+= 1
        }
        return derived.prefix(outputByteCount)
    }
}

public struct SecurityQuestionAnswerVerifier: Sendable {
    public let hasher: SecurityQuestionAnswerHasher

    public init(hasher: SecurityQuestionAnswerHasher = SecurityQuestionAnswerHasher()) {
        self.hasher = hasher
    }

    public func makeCredential(for answer: String) throws -> SecurityQuestionAnswerCredential {
        try hasher.makeCredential(for: answer)
    }

    public func verify(
        _ answer: String,
        against credential: SecurityQuestionAnswerCredential
    ) -> SecurityQuestionAnswerVerdict {
        switch credential {
        case .legacyUnsaltedSHA256(let hexDigest):
            let normalized = SecurityQuestionAnswerNormalizer.legacyNormalized(answer)
            guard !normalized.isEmpty else {
                return .mismatched
            }
            let digest = Self.legacySHA256Hex(forLegacyNormalizedAnswer: normalized)
            return constantTimeHexEquals(digest, hexDigest) ? .legacyMatched : .mismatched
        case .kdf(let record):
            return verify(answer, against: record)
        }
    }

    public func verify(
        _ answer: String,
        against record: SecurityQuestionAnswerRecord
    ) -> SecurityQuestionAnswerVerdict {
        if let failure = record.validationFailure() {
            return .invalidRecord(failure)
        }
        let normalized = SecurityQuestionAnswerNormalizer.normalized(answer)
        guard !normalized.isEmpty else {
            return .mismatched
        }
        do {
            let digest = try SecurityQuestionAnswerHasher.deriveDigest(
                normalizedAnswer: normalized,
                salt: record.salt,
                algorithm: record.algorithm,
                parameters: record.parameters
            )
            guard constantTimeEquals(digest, record.digest) else {
                return .mismatched
            }
            return .matched(needsUpgrade: hasher.needsUpgrade(record))
        } catch {
            return .invalidRecord(error.localizedDescription)
        }
    }

    /// 仅在验证通过后调用：把旧格式或弱参数的答案透明重写为新记录。
    /// 返回 `nil` 表示两个答案都已是当前参数，无需迁移。
    public func upgradedSetup(
        for setup: SecurityQuestionRecoverySetup,
        answer1: String,
        answer2: String,
        verdict1: SecurityQuestionAnswerVerdict,
        verdict2: SecurityQuestionAnswerVerdict
    ) throws -> SecurityQuestionRecoverySetup? {
        let needsRehashAnswer1 = verdict1.requiresRehash
        let needsRehashAnswer2 = verdict2.requiresRehash
        guard needsRehashAnswer1 || needsRehashAnswer2 else {
            return nil
        }
        let upgradedAnswer1 = needsRehashAnswer1 ? try makeCredential(for: answer1) : setup.answer1
        let upgradedAnswer2 = needsRehashAnswer2 ? try makeCredential(for: answer2) : setup.answer2
        return setup.replacingAnswers(answer1: upgradedAnswer1, answer2: upgradedAnswer2)
    }

    public static func legacySHA256Hex(forLegacyNormalizedAnswer answer: String) -> String {
        SecurityQuestionHex.encode(SHA256.hash(data: Data(answer.utf8)))
    }

    public static func legacySHA256Hex(for answer: String) -> String {
        legacySHA256Hex(
            forLegacyNormalizedAnswer: SecurityQuestionAnswerNormalizer.legacyNormalized(answer)
        )
    }
}

public struct SecurityQuestionVerificationThrottle: Sendable, Equatable {
    public struct State: Codable, Sendable, Equatable {
        public var failureCount: Int
        public var lockedUntil: Date?
        public var lastFailureAt: Date?

        public init(
            failureCount: Int = 0,
            lockedUntil: Date? = nil,
            lastFailureAt: Date? = nil
        ) {
            self.failureCount = failureCount
            self.lockedUntil = lockedUntil
            self.lastFailureAt = lastFailureAt
        }

        public static let clear = State()
    }

    public static let `default` = SecurityQuestionVerificationThrottle()

    public let freeAttempts: Int
    public let initialLockout: TimeInterval
    public let maximumLockout: TimeInterval

    public init(
        freeAttempts: Int = 2,
        initialLockout: TimeInterval = 60,
        maximumLockout: TimeInterval = 900
    ) {
        self.freeAttempts = max(0, freeAttempts)
        self.initialLockout = max(0, initialLockout)
        self.maximumLockout = max(self.initialLockout, maximumLockout)
    }

    public func remainingLockout(state: State, now: Date) -> TimeInterval {
        guard let lockedUntil = state.lockedUntil else {
            return 0
        }
        return max(0, lockedUntil.timeIntervalSince(now))
    }

    public func stateAfterFailure(state: State, now: Date) -> State {
        let failureCount = max(0, state.failureCount) + 1
        var next = State(
            failureCount: failureCount,
            lockedUntil: state.lockedUntil,
            lastFailureAt: now
        )
        if failureCount > freeAttempts {
            let exponent = min(failureCount - freeAttempts - 1, 16)
            let factor = pow(2.0, Double(exponent))
            let lockout = min(initialLockout * factor, maximumLockout)
            next.lockedUntil = now.addingTimeInterval(lockout)
        }
        return next
    }

    public func stateAfterSuccess() -> State {
        .clear
    }
}

enum SecurityQuestionHex {
    static func encode<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else {
        return false
    }
    var difference: UInt8 = 0
    for (left, right) in zip(lhs, rhs) {
        difference |= left ^ right
    }
    return difference == 0
}

private func constantTimeHexEquals(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.lowercased().utf8)
    let right = Array(rhs.lowercased().utf8)
    guard left.count == right.count else {
        return false
    }
    var difference: UInt8 = 0
    for index in left.indices {
        difference |= left[index] ^ right[index]
    }
    return difference == 0
}
