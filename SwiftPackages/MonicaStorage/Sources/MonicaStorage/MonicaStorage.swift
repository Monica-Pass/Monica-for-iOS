import Foundation
import CryptoKit
import MonicaMDBX
import MonicaStorageTwofish
import ZIPFoundation
import argon2
import zlib

public enum MonicaStorageBaseline {
    public static let primaryStore = "MDBX"
}

public enum KeePassContainerFormat: Sendable, Equatable {
    case kdbx
    case legacyKdb
    case unknown

    public var displayName: String {
        switch self {
        case .kdbx:
            return "KDBX"
        case .legacyKdb:
            return "KDB"
        case .unknown:
            return "未知格式"
        }
    }
}

public enum KeePassImportStatus: Sendable, Equatable {
    case requiresCredentials
    case readyToUnlock
    case unsupported
    case unknown
}

public enum KeePassKdbxFormatVersion: Sendable, Equatable {
    case kdbx3
    case kdbx4
    case unknown
}

public enum KeePassKdbxCipherAlgorithm: Sendable, Equatable {
    case aes256
    case chacha20
    case twofish
    case unknown(String)

    public var displayName: String {
        switch self {
        case .aes256:
            return "AES-256"
        case .chacha20:
            return "ChaCha20"
        case .twofish:
            return "Twofish"
        case let .unknown(identifier):
            return "未知 cipher(\(identifier))"
        }
    }
}

public enum KeePassKdbxCompressionAlgorithm: Sendable, Equatable {
    case none
    case gzip
    case unknown(UInt32)

    public var displayName: String {
        switch self {
        case .none:
            return "无压缩"
        case .gzip:
            return "GZip"
        case let .unknown(value):
            return "未知压缩(\(value))"
        }
    }
}

public enum KeePassKdbxKdfAlgorithm: Sendable, Equatable {
    case aesKdf
    case argon2d
    case argon2id
    case unknown(String)

    public var displayName: String {
        switch self {
        case .aesKdf:
            return "AES-KDF"
        case .argon2d:
            return "Argon2d"
        case .argon2id:
            return "Argon2id"
        case let .unknown(identifier):
            return "未知 KDF(\(identifier))"
        }
    }
}

public struct KeePassKdbxCryptoSummary: Sendable, Equatable {
    public let cipher: KeePassKdbxCipherAlgorithm?
    public let compression: KeePassKdbxCompressionAlgorithm?
    public let kdf: KeePassKdbxKdfAlgorithm?

    public init(
        cipher: KeePassKdbxCipherAlgorithm?,
        compression: KeePassKdbxCompressionAlgorithm?,
        kdf: KeePassKdbxKdfAlgorithm?
    ) {
        self.cipher = cipher
        self.compression = compression
        self.kdf = kdf
    }

    public var displaySummary: String {
        [
            cipher?.displayName,
            compression?.displayName,
            kdf?.displayName
        ]
        .compactMap { $0 }
        .joined(separator: "，")
    }
}

public struct KeePassKdbxArgon2Parameters: Sendable, Equatable {
    public let salt: Data?
    public let iterations: UInt64?
    public let memoryBytes: UInt64?
    public let parallelism: UInt32?
    public let version: UInt32?

    public init(
        salt: Data?,
        iterations: UInt64?,
        memoryBytes: UInt64?,
        parallelism: UInt32?,
        version: UInt32?
    ) {
        self.salt = salt
        self.iterations = iterations
        self.memoryBytes = memoryBytes
        self.parallelism = parallelism
        self.version = version
    }
}

public struct KeePassKdbxAesKdfParameters: Sendable, Equatable {
    public let seed: Data?
    public let rounds: UInt64?

    public init(seed: Data?, rounds: UInt64?) {
        self.seed = seed
        self.rounds = rounds
    }
}

public struct KeePassKdbxKdfParameters: Sendable, Equatable {
    public let algorithm: KeePassKdbxKdfAlgorithm
    public let argon2: KeePassKdbxArgon2Parameters?
    public let aesKdf: KeePassKdbxAesKdfParameters?

    public init(
        algorithm: KeePassKdbxKdfAlgorithm,
        argon2: KeePassKdbxArgon2Parameters? = nil,
        aesKdf: KeePassKdbxAesKdfParameters? = nil
    ) {
        self.algorithm = algorithm
        self.argon2 = argon2
        self.aesKdf = aesKdf
    }

    public var displaySummary: String {
        var parts = [algorithm.displayName]
        if let argon2 {
            if let memoryBytes = argon2.memoryBytes {
                parts.append("memory \(memoryBytes) bytes")
            }
            if let iterations = argon2.iterations {
                parts.append("iterations \(iterations)")
            }
            if let parallelism = argon2.parallelism {
                parts.append("parallelism \(parallelism)")
            }
            if let version = argon2.version {
                parts.append("version \(version)")
            }
        }
        if let aesKdf, let rounds = aesKdf.rounds {
            parts.append("rounds \(rounds)")
        }
        return parts.joined(separator: "，")
    }
}

public enum KeePassKdbxInnerRandomStreamAlgorithm: Sendable, Equatable {
    case none
    case arc4Variant
    case salsa20
    case chacha20
    case unknown(UInt32)

    public init(rawValue: UInt32?) {
        switch rawValue {
        case 0:
            self = .none
        case 1:
            self = .arc4Variant
        case 2:
            self = .salsa20
        case 3:
            self = .chacha20
        case let .some(value):
            self = .unknown(value)
        case .none:
            self = .unknown(0)
        }
    }

    public var displayName: String {
        switch self {
        case .none:
            return "None"
        case .arc4Variant:
            return "ArcFourVariant"
        case .salsa20:
            return "Salsa20"
        case .chacha20:
            return "ChaCha20"
        case let .unknown(value):
            return "未知 inner stream(\(value))"
        }
    }
}

public struct KeePassKdbxPayloadCryptoInputs: Sendable, Equatable {
    public let masterSeed: Data?
    public let encryptionIV: Data?
    public let innerRandomStreamKey: Data?
    public let streamStartBytes: Data?
    public let innerRandomStreamID: UInt32?

    public init(
        masterSeed: Data? = nil,
        encryptionIV: Data? = nil,
        innerRandomStreamKey: Data? = nil,
        streamStartBytes: Data? = nil,
        innerRandomStreamID: UInt32? = nil
    ) {
        self.masterSeed = masterSeed?.isEmpty == false ? masterSeed : nil
        self.encryptionIV = encryptionIV?.isEmpty == false ? encryptionIV : nil
        self.innerRandomStreamKey = innerRandomStreamKey?.isEmpty == false ? innerRandomStreamKey : nil
        self.streamStartBytes = streamStartBytes?.isEmpty == false ? streamStartBytes : nil
        self.innerRandomStreamID = innerRandomStreamID
    }

    public static let empty = KeePassKdbxPayloadCryptoInputs()

    public var innerRandomStreamAlgorithm: KeePassKdbxInnerRandomStreamAlgorithm {
        KeePassKdbxInnerRandomStreamAlgorithm(rawValue: innerRandomStreamID)
    }

    fileprivate func mergedWithKdbx4InnerHeader(
        innerRandomStreamKey: Data?,
        innerRandomStreamID: UInt32?
    ) -> KeePassKdbxPayloadCryptoInputs {
        KeePassKdbxPayloadCryptoInputs(
            masterSeed: masterSeed,
            encryptionIV: encryptionIV,
            innerRandomStreamKey: innerRandomStreamKey ?? self.innerRandomStreamKey,
            streamStartBytes: streamStartBytes,
            innerRandomStreamID: innerRandomStreamID ?? self.innerRandomStreamID
        )
    }

    public var displaySummary: String {
        var parts: [String] = []
        if let masterSeed {
            parts.append("master seed \(masterSeed.count) bytes")
        }
        if let encryptionIV {
            parts.append("IV \(encryptionIV.count) bytes")
        }
        if let streamStartBytes {
            parts.append("stream start \(streamStartBytes.count) bytes")
        }
        if innerRandomStreamID != nil || innerRandomStreamKey != nil {
            parts.append("inner stream \(innerRandomStreamAlgorithm.displayName)")
        }
        if let innerRandomStreamKey {
            parts.append("inner key \(innerRandomStreamKey.count) bytes")
        }
        return parts.isEmpty ? "crypto inputs unavailable" : parts.joined(separator: "，")
    }
}

public struct KeePassHeaderSummary: Sendable, Equatable {
    public let majorVersion: Int?
    public let minorVersion: Int?
    public let formatVersion: KeePassKdbxFormatVersion
    public let cryptoSummary: KeePassKdbxCryptoSummary?
    public let kdfParameters: KeePassKdbxKdfParameters?

    public init(
        majorVersion: Int?,
        minorVersion: Int?,
        formatVersion: KeePassKdbxFormatVersion,
        cryptoSummary: KeePassKdbxCryptoSummary? = nil,
        kdfParameters: KeePassKdbxKdfParameters? = nil
    ) {
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.formatVersion = formatVersion
        self.cryptoSummary = cryptoSummary?.displaySummary.isEmpty == true ? nil : cryptoSummary
        self.kdfParameters = kdfParameters
    }

    public var displayName: String {
        switch formatVersion {
        case .kdbx3:
            return "KDBX 3"
        case .kdbx4:
            return "KDBX 4"
        case .unknown:
            if let majorVersion {
                return "KDBX \(majorVersion)"
            }
            return "KDBX"
        }
    }
}

public struct KeePassKdbxPayloadEnvelope: Sendable, Equatable {
    public let headerSummary: KeePassHeaderSummary
    public let headerFields: [UInt8: Data]
    public let headerBytes: Data?
    public let headerByteRange: Range<Int>
    public let encryptedPayload: Data

    public init(
        headerSummary: KeePassHeaderSummary,
        headerFields: [UInt8: Data],
        headerBytes: Data? = nil,
        headerByteRange: Range<Int>,
        encryptedPayload: Data
    ) {
        self.headerSummary = headerSummary
        self.headerFields = headerFields
        self.headerBytes = headerBytes?.isEmpty == false ? headerBytes : nil
        self.headerByteRange = headerByteRange
        self.encryptedPayload = encryptedPayload
    }

    public static func parse(_ data: Data) throws -> KeePassKdbxPayloadEnvelope {
        try KeePassFormatInspector.parseKdbxPayloadEnvelope(data)
    }

    public var displaySummary: String {
        let crypto = headerSummary.cryptoSummary?.displaySummary
        let base = "\(headerSummary.displayName)，header \(headerByteRange.count) bytes，payload \(encryptedPayload.count) bytes"
        guard let crypto, !crypto.isEmpty else {
            return base
        }
        return "\(base)，\(crypto)"
    }
}

public struct KeePassKdbxCredentialMaterial: Sendable, Equatable {
    public let passwordKey: Data?
    public let keyFileKey: Data?
    public let compositeKey: Data

    public init(passwordKey: Data?, keyFileKey: Data?, compositeKey: Data) {
        self.passwordKey = passwordKey
        self.keyFileKey = keyFileKey
        self.compositeKey = compositeKey
    }

    public static func build(from candidate: KeePassCredentialCandidate) throws -> KeePassKdbxCredentialMaterial {
        let trimmedPassword = candidate.password.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordKey = trimmedPassword.isEmpty ? nil : Data(SHA256.hash(data: Data(candidate.password.utf8)))
        let keyFileKey = candidate.keyMaterial?.isEmpty == false ? candidate.keyMaterial : nil

        var combined = Data()
        if let passwordKey {
            combined.append(passwordKey)
        }
        if let keyFileKey {
            combined.append(keyFileKey)
        }
        guard !combined.isEmpty else {
            throw KeePassOperationError(
                code: .invalidCredential,
                message: "请输入数据库密码或选择密钥文件"
            )
        }

        return KeePassKdbxCredentialMaterial(
            passwordKey: passwordKey,
            keyFileKey: keyFileKey,
            compositeKey: Data(SHA256.hash(data: combined))
        )
    }

    public var componentSummary: String {
        switch (passwordKey != nil, keyFileKey != nil) {
        case (true, true):
            return "password + key file"
        case (true, false):
            return "password"
        case (false, true):
            return "key file"
        case (false, false):
            return "no credential material"
        }
    }
}

public struct KeePassKdbxDecryptInputContext: Sendable, Equatable {
    public let sourceName: String?
    public let candidateLabel: String
    public let envelope: KeePassKdbxPayloadEnvelope
    public let kdfParameters: KeePassKdbxKdfParameters?
    public let cryptoInputs: KeePassKdbxPayloadCryptoInputs
    public let credentialMaterial: KeePassKdbxCredentialMaterial

    public init(
        sourceName: String?,
        candidateLabel: String,
        envelope: KeePassKdbxPayloadEnvelope,
        kdfParameters: KeePassKdbxKdfParameters?,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs = .empty,
        credentialMaterial: KeePassKdbxCredentialMaterial
    ) {
        self.sourceName = sourceName
        self.candidateLabel = candidateLabel
        self.envelope = envelope
        self.kdfParameters = kdfParameters
        self.cryptoInputs = cryptoInputs
        self.credentialMaterial = credentialMaterial
    }

    public static func build(
        database: Data,
        sourceName: String?,
        credentialCandidate: KeePassCredentialCandidate
    ) throws -> KeePassKdbxDecryptInputContext {
        let envelope = try KeePassKdbxPayloadEnvelope.parse(database)
        return KeePassKdbxDecryptInputContext(
            sourceName: sourceName,
            candidateLabel: credentialCandidate.label,
            envelope: envelope,
            kdfParameters: envelope.headerSummary.kdfParameters,
            cryptoInputs: KeePassFormatInspector.parseKdbxPayloadCryptoInputs(from: envelope),
            credentialMaterial: try KeePassKdbxCredentialMaterial.build(from: credentialCandidate)
        )
    }

    public var displaySummary: String {
        let kdf = kdfParameters?.algorithm.displayName ?? "未知 KDF"
        let base = "\(envelope.headerSummary.displayName)，payload \(envelope.encryptedPayload.count) bytes，\(kdf)，candidate \(candidateLabel)，\(credentialMaterial.componentSummary)"
        let cryptoSummary = cryptoInputs.displaySummary
        guard cryptoSummary != "crypto inputs unavailable" else {
            return base
        }
        return "\(base)，\(cryptoSummary)"
    }
}

public protocol KeePassKdbxPayloadDecryptor: Sendable {
    func decryptPayload(_ context: KeePassKdbxDecryptInputContext) throws -> Data
}

public protocol KeePassKdbxPayloadCipher: Sendable {
    func decryptPayload(
        _ encryptedPayload: Data,
        cipher: KeePassKdbxCipherAlgorithm,
        masterKey: KeePassKdbxMasterKeyMaterial,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs
    ) throws -> Data

    func encryptPayload(
        _ plaintextPayload: Data,
        cipher: KeePassKdbxCipherAlgorithm,
        masterKey: KeePassKdbxMasterKeyMaterial,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs
    ) throws -> Data
}

public extension KeePassKdbxPayloadCipher {
    func encryptPayload(
        _ plaintextPayload: Data,
        cipher: KeePassKdbxCipherAlgorithm,
        masterKey: KeePassKdbxMasterKeyMaterial,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs
    ) throws -> Data {
        throw KeePassOperationError(
            code: .formatUnsupported,
            message: "KDBX payload 加密尚未接入"
        )
    }
}

public struct DefaultKeePassKdbxPayloadCipher: KeePassKdbxPayloadCipher {
    public init() {}

    public func decryptPayload(
        _ encryptedPayload: Data,
        cipher: KeePassKdbxCipherAlgorithm,
        masterKey: KeePassKdbxMasterKeyMaterial,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs
    ) throws -> Data {
        switch cipher {
        case .aes256:
            return try KeePassAES256CBC.decrypt(
                encryptedPayload,
                key: masterKey.material,
                iv: cryptoInputs.encryptionIV
            )
        case .chacha20:
            guard masterKey.material.count == 32 else {
                throw KeePassOperationError(
                    code: .formatUnsupported,
                    message: "KDBX ChaCha20 key 长度无效；请确认文件未损坏。"
                )
            }
            guard let iv = cryptoInputs.encryptionIV, iv.count == 12 else {
                throw KeePassOperationError(
                    code: .formatUnsupported,
                    message: "KDBX ChaCha20 IV 长度无效；请确认文件未损坏。"
                )
            }
            return KeePassChaCha20KeyStream(
                key: masterKey.material,
                nonce: iv
            ).xor(encryptedPayload)
        case .twofish:
            return try KeePassTwofishCBC.decrypt(
                encryptedPayload,
                key: masterKey.material,
                iv: cryptoInputs.encryptionIV
            )
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KDBX cipher 尚未接入"
            )
        }
    }

    public func encryptPayload(
        _ plaintextPayload: Data,
        cipher: KeePassKdbxCipherAlgorithm,
        masterKey: KeePassKdbxMasterKeyMaterial,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs
    ) throws -> Data {
        switch cipher {
        case .aes256:
            return try KeePassAES256CBC.encrypt(
                plaintextPayload,
                key: masterKey.material,
                iv: cryptoInputs.encryptionIV
            )
        case .chacha20:
            guard masterKey.material.count == 32 else {
                throw KeePassOperationError(
                    code: .formatUnsupported,
                    message: "KDBX ChaCha20 key 长度无效；请确认写回参数完整。"
                )
            }
            guard let iv = cryptoInputs.encryptionIV, iv.count == 12 else {
                throw KeePassOperationError(
                    code: .formatUnsupported,
                    message: "KDBX ChaCha20 IV 长度无效；请确认写回参数完整。"
                )
            }
            return KeePassChaCha20KeyStream(
                key: masterKey.material,
                nonce: iv
            ).xor(plaintextPayload)
        case .twofish:
            return try KeePassTwofishCBC.encrypt(
                plaintextPayload,
                key: masterKey.material,
                iv: cryptoInputs.encryptionIV
            )
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KDBX cipher 写回尚未接入"
            )
        }
    }
}

public protocol KeePassKdbx4HeaderWriter: Sendable {
    func writeHeader(
        cipher: KeePassKdbxCipherAlgorithm,
        compression: KeePassKdbxCompressionAlgorithm,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs,
        kdfParameters: KeePassKdbxKdfParameters
    ) throws -> Data
}

public struct DefaultKeePassKdbx4HeaderWriter: KeePassKdbx4HeaderWriter {
    public init() {}

    public func writeHeader(
        cipher: KeePassKdbxCipherAlgorithm,
        compression: KeePassKdbxCompressionAlgorithm,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs,
        kdfParameters: KeePassKdbxKdfParameters
    ) throws -> Data {
        let masterSeed = try requireLength(
            cryptoInputs.masterSeed,
            expected: 32,
            message: "KDBX4 master seed 长度无效；请确认写回参数完整。"
        )
        let encryptionIV = try requireLength(
            cryptoInputs.encryptionIV,
            expected: encryptionIVLength(for: cipher),
            message: "KDBX4 encryption IV 长度无效；请确认写回参数完整。"
        )

        var header = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x67, 0xFB, 0x4B, 0xB5,
            0x00, 0x00, 0x04, 0x00
        ])
        header.append(headerField(id: 2, value: try cipherUUID(for: cipher)))
        header.append(headerField(id: 3, value: try compressionFlags(for: compression)))
        header.append(headerField(id: 4, value: masterSeed))
        header.append(headerField(id: 7, value: encryptionIV))
        if let innerRandomStreamKey = cryptoInputs.innerRandomStreamKey {
            header.append(headerField(id: 8, value: innerRandomStreamKey))
        }
        if let streamStartBytes = cryptoInputs.streamStartBytes {
            header.append(headerField(id: 9, value: streamStartBytes))
        }
        if let innerRandomStreamID = cryptoInputs.innerRandomStreamID {
            header.append(headerField(id: 10, value: littleEndianUInt32(innerRandomStreamID)))
        }
        header.append(headerField(id: 11, value: try variantDictionary(for: kdfParameters)))
        header.append(headerField(id: 0, value: Data([0x0D, 0x0A, 0x0D, 0x0A])))
        return header
    }

    private func requireLength(_ data: Data?, expected: Int, message: String) throws -> Data {
        guard let data, data.count == expected else {
            throw KeePassOperationError(code: .formatUnsupported, message: message)
        }
        return data
    }

    private func encryptionIVLength(for cipher: KeePassKdbxCipherAlgorithm) throws -> Int {
        switch cipher {
        case .aes256, .twofish:
            return 16
        case .chacha20:
            return 12
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KDBX cipher header 写回尚未接入"
            )
        }
    }

    private func cipherUUID(for cipher: KeePassKdbxCipherAlgorithm) throws -> Data {
        switch cipher {
        case .aes256:
            return Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF])
        case .chacha20:
            return Data([0xD6, 0x03, 0x8A, 0x2B, 0x8B, 0x6F, 0x4C, 0xB5, 0xA5, 0x24, 0x33, 0x9A, 0x31, 0xDB, 0xB5, 0x9A])
        case .twofish:
            return Data([0xAD, 0x68, 0xF2, 0x9F, 0x57, 0x6F, 0x4B, 0xB9, 0xA3, 0x6A, 0xD4, 0x7A, 0xF9, 0x65, 0x34, 0x6C])
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KDBX cipher header 写回尚未接入"
            )
        }
    }

    private func compressionFlags(for compression: KeePassKdbxCompressionAlgorithm) throws -> Data {
        switch compression {
        case .none:
            return littleEndianUInt32(0)
        case .gzip:
            return littleEndianUInt32(1)
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KDBX compression header 写回尚未接入"
            )
        }
    }

    private func variantDictionary(for parameters: KeePassKdbxKdfParameters) throws -> Data {
        var entries: [Data] = []
        switch parameters.algorithm {
        case .aesKdf:
            guard let aesKdf = parameters.aesKdf else {
                throw KeePassOperationError(code: .formatUnsupported, message: "KDBX AES-KDF 参数缺失；请确认写回参数完整。")
            }
            entries.append(variantByteArray(key: "$UUID", value: Data([0xC9, 0xD9, 0xF3, 0x9A, 0x62, 0x8A, 0x44, 0x60, 0xBF, 0x74, 0x0D, 0x08, 0xC1, 0x8A, 0x4F, 0xEA])))
            entries.append(variantByteArray(
                key: "S",
                value: try requireLength(aesKdf.seed, expected: 32, message: "KDBX AES-KDF seed 长度无效；请确认写回参数完整。")
            ))
            guard let rounds = aesKdf.rounds else {
                throw KeePassOperationError(code: .formatUnsupported, message: "KDBX AES-KDF rounds 缺失；请确认写回参数完整。")
            }
            entries.append(variantUInt64(key: "R", value: rounds))
        case .argon2d, .argon2id:
            guard let argon2 = parameters.argon2 else {
                throw KeePassOperationError(code: .formatUnsupported, message: "KDBX Argon2 参数缺失；请确认写回参数完整。")
            }
            entries.append(variantByteArray(key: "$UUID", value: argon2UUID(for: parameters.algorithm)))
            guard let salt = argon2.salt, !salt.isEmpty else {
                throw KeePassOperationError(code: .formatUnsupported, message: "KDBX Argon2 salt 缺失；请确认写回参数完整。")
            }
            guard let iterations = argon2.iterations,
                  let memoryBytes = argon2.memoryBytes,
                  let parallelism = argon2.parallelism,
                  let version = argon2.version else {
                throw KeePassOperationError(code: .formatUnsupported, message: "KDBX Argon2 参数不完整；请确认写回参数完整。")
            }
            entries.append(variantByteArray(key: "S", value: salt))
            entries.append(variantUInt64(key: "I", value: iterations))
            entries.append(variantUInt64(key: "M", value: memoryBytes))
            entries.append(variantUInt32(key: "P", value: parallelism))
            entries.append(variantUInt32(key: "V", value: version))
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KDBX KDF header 写回尚未接入"
            )
        }

        var dictionary = Data([0x00, 0x01])
        for entry in entries {
            dictionary.append(entry)
        }
        dictionary.append(0x00)
        return dictionary
    }

    private func argon2UUID(for algorithm: KeePassKdbxKdfAlgorithm) -> Data {
        switch algorithm {
        case .argon2d:
            return Data([0xEF, 0x63, 0x6D, 0xDF, 0x8C, 0x29, 0x44, 0x4B, 0x91, 0xF7, 0xA9, 0xA4, 0x03, 0xE3, 0x0A, 0x0C])
        case .argon2id:
            return Data([0x9E, 0x29, 0x8B, 0x19, 0x56, 0xDB, 0x47, 0x73, 0xB2, 0x3D, 0xFC, 0x3E, 0xC6, 0xF0, 0xA1, 0xE6])
        default:
            return Data()
        }
    }

    private func headerField(id: UInt8, value: Data) -> Data {
        var field = Data([id])
        field.append(littleEndianUInt32(UInt32(value.count)))
        field.append(value)
        return field
    }

    private func variantByteArray(key: String, value: Data) -> Data {
        var data = Data([0x42])
        data.append(variantKeyAndLength(key: key, valueLength: value.count))
        data.append(value)
        return data
    }

    private func variantUInt32(key: String, value: UInt32) -> Data {
        var data = Data([0x04])
        data.append(variantKeyAndLength(key: key, valueLength: MemoryLayout<UInt32>.size))
        data.append(littleEndianUInt32(value))
        return data
    }

    private func variantUInt64(key: String, value: UInt64) -> Data {
        var data = Data([0x05])
        data.append(variantKeyAndLength(key: key, valueLength: MemoryLayout<UInt64>.size))
        data.append(littleEndianUInt64(value))
        return data
    }

    private func variantKeyAndLength(key: String, valueLength: Int) -> Data {
        let keyData = Data(key.utf8)
        var data = Data()
        data.append(littleEndianUInt32(UInt32(keyData.count)))
        data.append(keyData)
        data.append(littleEndianUInt32(UInt32(valueLength)))
        return data
    }

    private func littleEndianUInt32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    private func littleEndianUInt64(_ value: UInt64) -> Data {
        Data((0..<8).map { UInt8((value >> UInt64($0 * 8)) & 0xFF) })
    }
}

public protocol KeePassKdbx3HeaderWriter: Sendable {
    func writeHeader(
        cipher: KeePassKdbxCipherAlgorithm,
        compression: KeePassKdbxCompressionAlgorithm,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs,
        kdfParameters: KeePassKdbxKdfParameters
    ) throws -> Data
}

public struct DefaultKeePassKdbx3HeaderWriter: KeePassKdbx3HeaderWriter {
    public init() {}

    public func writeHeader(
        cipher: KeePassKdbxCipherAlgorithm,
        compression: KeePassKdbxCompressionAlgorithm,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs,
        kdfParameters: KeePassKdbxKdfParameters
    ) throws -> Data {
        guard kdfParameters.algorithm == .aesKdf,
              let aesKdf = kdfParameters.aesKdf else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX3 writeback 仅支持 legacy AES-KDF 参数。"
            )
        }
        let masterSeed = try requireLength(
            cryptoInputs.masterSeed,
            expected: 32,
            message: "KDBX3 master seed 长度无效；请确认写回参数完整。"
        )
        let transformSeed = try requireLength(
            aesKdf.seed,
            expected: 32,
            message: "KDBX3 AES-KDF seed 长度无效；请确认写回参数完整。"
        )
        guard let transformRounds = aesKdf.rounds else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX3 AES-KDF rounds 缺失；请确认写回参数完整。"
            )
        }
        let encryptionIV = try requireLength(
            cryptoInputs.encryptionIV,
            expected: encryptionIVLength(for: cipher),
            message: "KDBX3 encryption IV 长度无效；请确认写回参数完整。"
        )
        let innerRandomStreamKey = try requireLength(
            cryptoInputs.innerRandomStreamKey,
            expected: 32,
            message: "KDBX3 protected stream key 长度无效；请确认写回参数完整。"
        )
        let streamStartBytes = try requireLength(
            cryptoInputs.streamStartBytes,
            expected: 32,
            message: "KDBX3 stream start bytes 长度无效；请确认写回参数完整。"
        )
        guard let innerRandomStreamID = cryptoInputs.innerRandomStreamID else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX3 inner stream 参数缺失；请确认写回参数完整。"
            )
        }

        var header = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x67, 0xFB, 0x4B, 0xB5,
            0x01, 0x00, 0x03, 0x00
        ])
        header.append(headerField(id: 2, value: try cipherUUID(for: cipher)))
        header.append(headerField(id: 3, value: try compressionFlags(for: compression)))
        header.append(headerField(id: 4, value: masterSeed))
        header.append(headerField(id: 5, value: transformSeed))
        header.append(headerField(id: 6, value: littleEndianUInt64(transformRounds)))
        header.append(headerField(id: 7, value: encryptionIV))
        header.append(headerField(id: 8, value: innerRandomStreamKey))
        header.append(headerField(id: 9, value: streamStartBytes))
        header.append(headerField(id: 10, value: littleEndianUInt32(innerRandomStreamID)))
        header.append(headerField(id: 0, value: Data([0x0D, 0x0A, 0x0D, 0x0A])))
        return header
    }

    private func requireLength(_ data: Data?, expected: Int, message: String) throws -> Data {
        guard let data, data.count == expected else {
            throw KeePassOperationError(code: .formatUnsupported, message: message)
        }
        return data
    }

    private func encryptionIVLength(for cipher: KeePassKdbxCipherAlgorithm) throws -> Int {
        switch cipher {
        case .aes256, .twofish:
            return 16
        case .chacha20:
            return 12
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KDBX3 cipher header 写回尚未接入"
            )
        }
    }

    private func cipherUUID(for cipher: KeePassKdbxCipherAlgorithm) throws -> Data {
        switch cipher {
        case .aes256:
            return Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF])
        case .chacha20:
            return Data([0xD6, 0x03, 0x8A, 0x2B, 0x8B, 0x6F, 0x4C, 0xB5, 0xA5, 0x24, 0x33, 0x9A, 0x31, 0xDB, 0xB5, 0x9A])
        case .twofish:
            return Data([0xAD, 0x68, 0xF2, 0x9F, 0x57, 0x6F, 0x4B, 0xB9, 0xA3, 0x6A, 0xD4, 0x7A, 0xF9, 0x65, 0x34, 0x6C])
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KDBX3 cipher header 写回尚未接入"
            )
        }
    }

    private func compressionFlags(for compression: KeePassKdbxCompressionAlgorithm) throws -> Data {
        switch compression {
        case .none:
            return littleEndianUInt32(0)
        case .gzip:
            return littleEndianUInt32(1)
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KDBX3 compression header 写回尚未接入"
            )
        }
    }

    private func headerField(id: UInt8, value: Data) -> Data {
        var field = Data([id])
        var length = UInt16(value.count).littleEndian
        field.append(Data(bytes: &length, count: MemoryLayout<UInt16>.size))
        field.append(value)
        return field
    }

    private func littleEndianUInt32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    private func littleEndianUInt64(_ value: UInt64) -> Data {
        Data((0..<8).map { UInt8((value >> UInt64($0 * 8)) & 0xFF) })
    }
}

public struct KeePassKdbxBlockStreamContext: Sendable, Equatable {
    public let formatVersion: KeePassKdbxFormatVersion
    public let streamStartBytes: Data?
    public let hmacBlockBaseKey: Data?

    public init(formatVersion: KeePassKdbxFormatVersion, streamStartBytes: Data?, hmacBlockBaseKey: Data? = nil) {
        self.formatVersion = formatVersion
        self.streamStartBytes = streamStartBytes?.isEmpty == false ? streamStartBytes : nil
        self.hmacBlockBaseKey = hmacBlockBaseKey?.isEmpty == false ? hmacBlockBaseKey : nil
    }
}

public protocol KeePassKdbxBlockStreamDecoder: Sendable {
    func decodeBlockStream(_ decryptedPayload: Data, context: KeePassKdbxBlockStreamContext) throws -> Data
}

public protocol KeePassKdbxBlockStreamEncoder: Sendable {
    func encodeBlockStream(_ xmlPayload: Data, context: KeePassKdbxBlockStreamContext) throws -> Data
}

public struct DefaultKeePassKdbxBlockStreamEncoder: KeePassKdbxBlockStreamEncoder {
    public init() {}

    public func encodeBlockStream(_ xmlPayload: Data, context: KeePassKdbxBlockStreamContext) throws -> Data {
        switch context.formatVersion {
        case .kdbx3:
            return try encodeKdbx3HashedBlockStream(xmlPayload, streamStartBytes: context.streamStartBytes)
        case .kdbx4:
            return try encodeKdbx4HmacBlockStream(xmlPayload, hmacBlockBaseKey: context.hmacBlockBaseKey)
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KDBX block stream 写回尚未接入"
            )
        }
    }

    private func encodeKdbx3HashedBlockStream(_ xmlPayload: Data, streamStartBytes: Data?) throws -> Data {
        guard let streamStartBytes, !streamStartBytes.isEmpty else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX stream start bytes 缺失；请确认文件未损坏。"
            )
        }
        guard xmlPayload.count <= Int(UInt32.max) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX block stream 写回 payload 过大；请拆分后重试。"
            )
        }

        var encoded = Data()
        encoded.append(streamStartBytes)
        if !xmlPayload.isEmpty {
            encoded.append(littleEndianUInt32(0))
            encoded.append(Data(SHA256.hash(data: xmlPayload)))
            encoded.append(littleEndianUInt32(UInt32(xmlPayload.count)))
            encoded.append(xmlPayload)
        }
        encoded.append(littleEndianUInt32(xmlPayload.isEmpty ? 0 : 1))
        encoded.append(Data(repeating: 0x00, count: SHA256.byteCount))
        encoded.append(littleEndianUInt32(0))
        return encoded
    }

    private func encodeKdbx4HmacBlockStream(_ xmlPayload: Data, hmacBlockBaseKey: Data?) throws -> Data {
        guard let hmacBlockBaseKey, hmacBlockBaseKey.count == SHA512.byteCount else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX4 HMAC key 缺失；请确认文件未损坏。"
            )
        }
        guard xmlPayload.count <= Int(UInt32.max) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX4 block stream 写回 payload 过大；请拆分后重试。"
            )
        }

        var encoded = Data()
        var nextBlockIndex: UInt64 = 0
        if !xmlPayload.isEmpty {
            encoded.append(kdbx4BlockHmac(blockIndex: nextBlockIndex, blockLength: UInt32(xmlPayload.count), block: xmlPayload, hmacBlockBaseKey: hmacBlockBaseKey))
            encoded.append(littleEndianUInt32(UInt32(xmlPayload.count)))
            encoded.append(xmlPayload)
            nextBlockIndex += 1
        }

        let terminator = Data()
        encoded.append(kdbx4BlockHmac(blockIndex: nextBlockIndex, blockLength: 0, block: terminator, hmacBlockBaseKey: hmacBlockBaseKey))
        encoded.append(littleEndianUInt32(0))
        return encoded
    }

    private func kdbx4BlockHmac(blockIndex: UInt64, blockLength: UInt32, block: Data, hmacBlockBaseKey: Data) -> Data {
        let blockKeyInput = littleEndianUInt64(blockIndex) + hmacBlockBaseKey
        let blockKey = SymmetricKey(data: Data(SHA512.hash(data: blockKeyInput)))
        var hmacInput = Data()
        hmacInput.append(littleEndianUInt64(blockIndex))
        hmacInput.append(littleEndianUInt32(blockLength))
        hmacInput.append(block)
        return Data(HMAC<SHA256>.authenticationCode(for: hmacInput, using: blockKey))
    }

    private func littleEndianUInt32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    private func littleEndianUInt64(_ value: UInt64) -> Data {
        Data((0..<8).map { UInt8((value >> UInt64($0 * 8)) & 0xFF) })
    }
}

public protocol KeePassKdbx4PayloadSectionWriter: Sendable {
    func writePayloadSection(
        encryptedPayloadBlocks: [Data],
        headerBytes: Data,
        masterSeed: Data,
        derivedKey: KeePassKdbxDerivedKey
    ) throws -> Data
}

public struct DefaultKeePassKdbx4PayloadSectionWriter: KeePassKdbx4PayloadSectionWriter {
    private let blockStreamEncoder: any KeePassKdbxBlockStreamEncoder

    public init(blockStreamEncoder: any KeePassKdbxBlockStreamEncoder = DefaultKeePassKdbxBlockStreamEncoder()) {
        self.blockStreamEncoder = blockStreamEncoder
    }

    public func writePayloadSection(
        encryptedPayloadBlocks: [Data],
        headerBytes: Data,
        masterSeed: Data,
        derivedKey: KeePassKdbxDerivedKey
    ) throws -> Data {
        let hmacBlockBaseKey = try kdbx4HmacBlockBaseKey(masterSeed: masterSeed, derivedKey: derivedKey)
        var payloadSection = Data(SHA256.hash(data: headerBytes))
        payloadSection.append(kdbx4HeaderHmac(headerBytes: headerBytes, hmacBlockBaseKey: hmacBlockBaseKey))
        payloadSection.append(try blockStreamEncoder.encodeBlockStream(
            encryptedPayloadBlocks.reduce(into: Data()) { output, block in
                output.append(block)
            },
            context: KeePassKdbxBlockStreamContext(
                formatVersion: .kdbx4,
                streamStartBytes: nil,
                hmacBlockBaseKey: hmacBlockBaseKey
            )
        ))
        return payloadSection
    }

    private func kdbx4HmacBlockBaseKey(masterSeed: Data, derivedKey: KeePassKdbxDerivedKey) throws -> Data {
        guard masterSeed.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX4 HMAC master seed 长度无效；请确认文件未损坏。"
            )
        }
        guard derivedKey.material.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX4 HMAC derived key 长度无效；请确认文件未损坏。"
            )
        }
        var input = Data()
        input.append(masterSeed)
        input.append(derivedKey.material)
        input.append(0x01)
        return Data(SHA512.hash(data: input))
    }

    private func kdbx4HeaderHmac(headerBytes: Data, hmacBlockBaseKey: Data) -> Data {
        let headerKey = Data(SHA512.hash(data: littleEndianUInt64(UInt64.max) + hmacBlockBaseKey))
        return Data(HMAC<SHA256>.authenticationCode(for: headerBytes, using: SymmetricKey(data: headerKey)))
    }

    private func littleEndianUInt64(_ value: UInt64) -> Data {
        Data((0..<8).map { UInt8((value >> UInt64($0 * 8)) & 0xFF) })
    }
}

public protocol KeePassKdbxFileAssembler: Sendable {
    func assemble(headerBytes: Data, payloadSection: Data) throws -> Data
}

public struct DefaultKeePassKdbxFileAssembler: KeePassKdbxFileAssembler {
    public init() {}

    public func assemble(headerBytes: Data, payloadSection: Data) throws -> Data {
        guard !payloadSection.isEmpty else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX payload section 缺失；请确认写回数据完整。"
            )
        }
        _ = try KeePassKdbxPayloadEnvelope.parse(headerBytes)

        var database = Data()
        database.reserveCapacity(headerBytes.count + payloadSection.count)
        database.append(headerBytes)
        database.append(payloadSection)
        return database
    }
}

public struct DefaultKeePassKdbxBlockStreamDecoder: KeePassKdbxBlockStreamDecoder {
    public init() {}

    public func decodeBlockStream(_ decryptedPayload: Data, context: KeePassKdbxBlockStreamContext) throws -> Data {
        switch context.formatVersion {
        case .kdbx3:
            return try decodeKdbx3HashedBlockStream(decryptedPayload, streamStartBytes: context.streamStartBytes)
        case .kdbx4:
            return try decodeKdbx4HmacBlockStream(decryptedPayload, hmacBlockBaseKey: context.hmacBlockBaseKey)
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KDBX block stream 尚未接入"
            )
        }
    }

    private func decodeKdbx3HashedBlockStream(_ decryptedPayload: Data, streamStartBytes: Data?) throws -> Data {
        guard let streamStartBytes, !streamStartBytes.isEmpty else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX stream start bytes 缺失；请确认文件未损坏。"
            )
        }
        guard decryptedPayload.count >= streamStartBytes.count,
              Data(decryptedPayload[decryptedPayload.startIndex..<decryptedPayload.startIndex + streamStartBytes.count]) == streamStartBytes else {
            throw KeePassOperationError(
                code: .invalidCredential,
                message: "KDBX stream start 校验失败；请确认数据库密码或密钥文件。"
            )
        }

        var offset = streamStartBytes.count
        var expectedBlockIndex: UInt32 = 0
        var decoded = Data()
        while true {
            let blockIndex = try readLittleEndianUInt32(from: decryptedPayload, offset: &offset)
            guard blockIndex == expectedBlockIndex else {
                throw KeePassOperationError(
                    code: .formatUnsupported,
                    message: "KDBX block index 无效；请确认文件未损坏。"
                )
            }
            let expectedHash = try readBytes(from: decryptedPayload, offset: &offset, count: 32)
            let blockLength = try readLittleEndianUInt32(from: decryptedPayload, offset: &offset)
            if blockLength == 0 {
                guard expectedHash == Data(repeating: 0x00, count: 32) else {
                    throw KeePassOperationError(
                        code: .formatUnsupported,
                        message: "KDBX block terminator 无效；请确认文件未损坏。"
                    )
                }
                guard offset == decryptedPayload.count else {
                    throw KeePassOperationError(
                        code: .formatUnsupported,
                        message: "KDBX block stream 末尾无效；请确认文件未损坏。"
                    )
                }
                return decoded
            }
            let block = try readBytes(from: decryptedPayload, offset: &offset, count: Int(blockLength))
            guard Data(SHA256.hash(data: block)) == expectedHash else {
                throw KeePassOperationError(
                    code: .invalidCredential,
                    message: "KDBX block hash 校验失败；请确认数据库密码、密钥文件或文件完整性。"
                )
            }
            decoded.append(block)
            expectedBlockIndex += 1
        }
    }

    private func decodeKdbx4HmacBlockStream(_ hmacBlockStream: Data, hmacBlockBaseKey: Data?) throws -> Data {
        guard let hmacBlockBaseKey, hmacBlockBaseKey.count == SHA512.byteCount else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX4 HMAC key 缺失；请确认文件未损坏。"
            )
        }

        var offset = 0
        var blockIndex: UInt64 = 0
        var decoded = Data()
        while true {
            let expectedHmac = try readBytes(from: hmacBlockStream, offset: &offset, count: SHA256.byteCount)
            let blockLength = try readLittleEndianUInt32(from: hmacBlockStream, offset: &offset)
            let block = try readBytes(from: hmacBlockStream, offset: &offset, count: Int(blockLength))
            let actualHmac = kdbx4BlockHmac(blockIndex: blockIndex, blockLength: blockLength, block: block, hmacBlockBaseKey: hmacBlockBaseKey)
            guard actualHmac == expectedHmac else {
                throw KeePassOperationError(
                    code: .invalidCredential,
                    message: "KDBX4 block HMAC 校验失败；请确认数据库密码、密钥文件或文件完整性。"
                )
            }
            if blockLength == 0 {
                guard offset == hmacBlockStream.count else {
                    throw KeePassOperationError(
                        code: .formatUnsupported,
                        message: "KDBX4 block stream 末尾无效；请确认文件未损坏。"
                    )
                }
                return decoded
            }
            decoded.append(block)
            blockIndex += 1
        }
    }

    private func kdbx4BlockHmac(blockIndex: UInt64, blockLength: UInt32, block: Data, hmacBlockBaseKey: Data) -> Data {
        let blockKeyInput = littleEndianUInt64(blockIndex) + hmacBlockBaseKey
        let blockKey = SymmetricKey(data: Data(SHA512.hash(data: blockKeyInput)))
        var hmacInput = Data()
        hmacInput.append(littleEndianUInt64(blockIndex))
        hmacInput.append(littleEndianUInt32(blockLength))
        hmacInput.append(block)
        return Data(HMAC<SHA256>.authenticationCode(for: hmacInput, using: blockKey))
    }

    private func readLittleEndianUInt32(from data: Data, offset: inout Int) throws -> UInt32 {
        let bytes = try readBytes(from: data, offset: &offset, count: 4)
        var value: UInt32 = 0
        for byteOffset in 0..<4 {
            value |= UInt32(bytes[bytes.startIndex + byteOffset]) << UInt32(byteOffset * 8)
        }
        return value
    }

    private func readBytes(from data: Data, offset: inout Int, count: Int) throws -> Data {
        guard count >= 0,
              offset >= 0,
              offset + count <= data.count else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX block stream 无法解析；请确认文件未损坏。"
            )
        }
        defer { offset += count }
        return Data(data[offset..<offset + count])
    }

    private func littleEndianUInt32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    private func littleEndianUInt64(_ value: UInt64) -> Data {
        Data((0..<8).map { UInt8((value >> UInt64($0 * 8)) & 0xFF) })
    }
}

public struct DefaultKeePassKdbxPayloadDecryptor: KeePassKdbxPayloadDecryptor {
    private let keyDeriver: any KeePassKdbxKeyDeriver
    private let masterKeyComposer: any KeePassKdbxMasterKeyComposer
    private let payloadCipher: any KeePassKdbxPayloadCipher
    private let blockStreamDecoder: any KeePassKdbxBlockStreamDecoder

    public init(
        keyDeriver: any KeePassKdbxKeyDeriver = DefaultKeePassKdbxKeyDeriver(),
        masterKeyComposer: any KeePassKdbxMasterKeyComposer = DefaultKeePassKdbxMasterKeyComposer(),
        payloadCipher: any KeePassKdbxPayloadCipher = DefaultKeePassKdbxPayloadCipher(),
        blockStreamDecoder: any KeePassKdbxBlockStreamDecoder = DefaultKeePassKdbxBlockStreamDecoder()
    ) {
        self.keyDeriver = keyDeriver
        self.masterKeyComposer = masterKeyComposer
        self.payloadCipher = payloadCipher
        self.blockStreamDecoder = blockStreamDecoder
    }

    public func decryptPayload(_ context: KeePassKdbxDecryptInputContext) throws -> Data {
        let derivedKey = try keyDeriver.deriveKey(from: context)
        let masterKey = try masterKeyComposer.composeMasterKey(
            from: derivedKey,
            cryptoInputs: context.cryptoInputs
        )
        guard let cipher = context.envelope.headerSummary.cryptoSummary?.cipher else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX cipher 参数缺失；请确认文件未损坏。"
            )
        }
        let cipherInput = try payloadCipherInput(from: context, derivedKey: derivedKey)
        let decryptedPayload = try payloadCipher.decryptPayload(
            cipherInput,
            cipher: cipher,
            masterKey: masterKey,
            cryptoInputs: context.cryptoInputs
        )
        if context.envelope.headerSummary.formatVersion == .kdbx4 {
            return decryptedPayload
        }
        return try blockStreamDecoder.decodeBlockStream(
            decryptedPayload,
            context: KeePassKdbxBlockStreamContext(
                formatVersion: context.envelope.headerSummary.formatVersion,
                streamStartBytes: context.cryptoInputs.streamStartBytes
            )
        )
    }

    private func payloadCipherInput(from context: KeePassKdbxDecryptInputContext, derivedKey: KeePassKdbxDerivedKey) throws -> Data {
        guard context.envelope.headerSummary.formatVersion == .kdbx4 else {
            return context.envelope.encryptedPayload
        }
        let hmacBlockBaseKey = try kdbx4HmacBlockBaseKey(from: context.cryptoInputs, derivedKey: derivedKey)
        return try blockStreamDecoder.decodeBlockStream(
            try kdbx4HmacBlockStreamPayload(
                from: context.envelope.encryptedPayload,
                headerBytes: context.envelope.headerBytes,
                hmacBlockBaseKey: hmacBlockBaseKey
            ),
            context: KeePassKdbxBlockStreamContext(
                formatVersion: .kdbx4,
                streamStartBytes: nil,
                hmacBlockBaseKey: hmacBlockBaseKey
            )
        )
    }

    private func kdbx4HmacBlockStreamPayload(
        from payloadSection: Data,
        headerBytes: Data?,
        hmacBlockBaseKey: Data
    ) throws -> Data {
        let headerAuthenticationByteCount = SHA256.byteCount + SHA256.byteCount
        guard payloadSection.count >= headerAuthenticationByteCount else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX4 header authentication bytes 缺失；请确认文件未损坏。"
            )
        }
        if let headerBytes {
            let headerHash = Data(payloadSection.prefix(SHA256.byteCount))
            let headerHmacStart = payloadSection.startIndex + SHA256.byteCount
            let headerHmacEnd = headerHmacStart + SHA256.byteCount
            let headerHmac = Data(payloadSection[headerHmacStart..<headerHmacEnd])
            guard Data(SHA256.hash(data: headerBytes)) == headerHash else {
                throw KeePassOperationError(
                    code: .formatUnsupported,
                    message: "KDBX4 header hash 校验失败；请确认文件未损坏。"
                )
            }
            let headerHmacKey = kdbx4HeaderHmacKey(hmacBlockBaseKey: hmacBlockBaseKey)
            let expectedHmac = Data(HMAC<SHA256>.authenticationCode(for: headerBytes, using: SymmetricKey(data: headerHmacKey)))
            guard expectedHmac == headerHmac else {
                throw KeePassOperationError(
                    code: .invalidCredential,
                    message: "KDBX4 header HMAC 校验失败；请确认数据库密码、密钥文件或文件完整性。"
                )
            }
        }
        return Data(payloadSection.dropFirst(headerAuthenticationByteCount))
    }

    private func kdbx4HeaderHmacKey(hmacBlockBaseKey: Data) -> Data {
        Data(SHA512.hash(data: littleEndianUInt64(UInt64.max) + hmacBlockBaseKey))
    }

    private func kdbx4HmacBlockBaseKey(
        from cryptoInputs: KeePassKdbxPayloadCryptoInputs,
        derivedKey: KeePassKdbxDerivedKey
    ) throws -> Data {
        guard let masterSeed = cryptoInputs.masterSeed else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX4 HMAC master seed 缺失；请确认文件未损坏。"
            )
        }
        guard masterSeed.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX4 HMAC master seed 长度无效；请确认文件未损坏。"
            )
        }
        guard derivedKey.material.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX4 HMAC derived key 长度无效；请确认文件未损坏。"
            )
        }
        var input = Data()
        input.append(masterSeed)
        input.append(derivedKey.material)
        input.append(0x01)
        return Data(SHA512.hash(data: input))
    }

    private func littleEndianUInt64(_ value: UInt64) -> Data {
        Data((0..<8).map { UInt8((value >> UInt64($0 * 8)) & 0xFF) })
    }
}

public struct UnsupportedKeePassKdbxPayloadDecryptor: KeePassKdbxPayloadDecryptor {
    private let decryptor: DefaultKeePassKdbxPayloadDecryptor

    public init(
        keyDeriver: any KeePassKdbxKeyDeriver = DefaultKeePassKdbxKeyDeriver(),
        masterKeyComposer: any KeePassKdbxMasterKeyComposer = DefaultKeePassKdbxMasterKeyComposer()
    ) {
        self.decryptor = DefaultKeePassKdbxPayloadDecryptor(
            keyDeriver: keyDeriver,
            masterKeyComposer: masterKeyComposer
        )
    }

    public func decryptPayload(_ context: KeePassKdbxDecryptInputContext) throws -> Data {
        try decryptor.decryptPayload(context)
    }
}

public struct KeePassKdbxDerivedKey: Sendable, Equatable {
    public let algorithm: KeePassKdbxKdfAlgorithm
    public let material: Data
    public let rounds: UInt64?

    public init(algorithm: KeePassKdbxKdfAlgorithm, material: Data, rounds: UInt64?) {
        self.algorithm = algorithm
        self.material = material
        self.rounds = rounds
    }

    public var displaySummary: String {
        var parts = [algorithm.displayName]
        if let rounds {
            parts.append("rounds \(rounds)")
        }
        parts.append("derived key \(material.count) bytes")
        return parts.joined(separator: "，")
    }
}

public struct KeePassKdbxMasterKeyMaterial: Sendable, Equatable {
    public let algorithm: KeePassKdbxKdfAlgorithm
    public let material: Data

    public init(algorithm: KeePassKdbxKdfAlgorithm, material: Data) {
        self.algorithm = algorithm
        self.material = material
    }

    public var displaySummary: String {
        "\(algorithm.displayName)，master key \(material.count) bytes"
    }
}

public protocol KeePassKdbxMasterKeyComposer: Sendable {
    func composeMasterKey(
        from derivedKey: KeePassKdbxDerivedKey,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs
    ) throws -> KeePassKdbxMasterKeyMaterial
}

public struct DefaultKeePassKdbxMasterKeyComposer: KeePassKdbxMasterKeyComposer {
    public init() {}

    public func composeMasterKey(
        from derivedKey: KeePassKdbxDerivedKey,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs
    ) throws -> KeePassKdbxMasterKeyMaterial {
        guard let masterSeed = cryptoInputs.masterSeed else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX master seed 缺失；请确认文件未损坏。"
            )
        }
        guard masterSeed.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX master seed 长度无效；请确认文件未损坏。"
            )
        }
        guard derivedKey.material.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX derived key 长度无效；请确认文件未损坏。"
            )
        }

        var combined = Data()
        combined.append(masterSeed)
        combined.append(derivedKey.material)
        return KeePassKdbxMasterKeyMaterial(
            algorithm: derivedKey.algorithm,
            material: Data(SHA256.hash(data: combined))
        )
    }
}

public protocol KeePassKdbxKeyDeriver: Sendable {
    func deriveKey(from context: KeePassKdbxDecryptInputContext) throws -> KeePassKdbxDerivedKey
}

public struct DefaultKeePassKdbxKeyDeriver: KeePassKdbxKeyDeriver {
    public init() {}

    public func deriveKey(from context: KeePassKdbxDecryptInputContext) throws -> KeePassKdbxDerivedKey {
        guard let parameters = context.kdfParameters else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX KDF 参数缺失；请确认文件未损坏。"
            )
        }

        switch parameters.algorithm {
        case .aesKdf:
            return try deriveAESKdfKey(from: context, parameters: parameters)
        case .argon2d, .argon2id:
            return try deriveArgon2Key(from: context, parameters: parameters)
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KDBX KDF 尚未接入"
            )
        }
    }

    private func deriveAESKdfKey(
        from context: KeePassKdbxDecryptInputContext,
        parameters: KeePassKdbxKdfParameters
    ) throws -> KeePassKdbxDerivedKey {
        guard let aesKdf = parameters.aesKdf,
              let seed = aesKdf.seed,
              let rounds = aesKdf.rounds else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX AES-KDF 参数缺失；请确认文件未损坏。"
            )
        }
        guard seed.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX AES-KDF seed 长度无效；请确认文件未损坏。"
            )
        }
        guard rounds > 0 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX AES-KDF rounds 无效；请确认文件未损坏。"
            )
        }

        let transformedKey = try KeePassAES256ECB.transform(
            context.credentialMaterial.compositeKey,
            key: seed,
            rounds: rounds
        )
        return KeePassKdbxDerivedKey(
            algorithm: .aesKdf,
            material: Data(SHA256.hash(data: transformedKey)),
            rounds: rounds
        )
    }

    private func deriveArgon2Key(
        from context: KeePassKdbxDecryptInputContext,
        parameters: KeePassKdbxKdfParameters
    ) throws -> KeePassKdbxDerivedKey {
        guard let argon2Parameters = parameters.argon2,
              let salt = argon2Parameters.salt,
              let iterations = argon2Parameters.iterations,
              let memoryBytes = argon2Parameters.memoryBytes,
              let parallelism = argon2Parameters.parallelism else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "\(parameters.algorithm.displayName) KDF 参数缺失；请确认文件未损坏。"
            )
        }
        guard salt.count >= 8 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "\(parameters.algorithm.displayName) KDF salt 长度无效；请确认文件未损坏。"
            )
        }
        guard iterations > 0 && iterations <= UInt64(UInt32.max) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "\(parameters.algorithm.displayName) KDF iterations 无效；请确认文件未损坏。"
            )
        }
        guard memoryBytes >= 1024 && memoryBytes % 1024 == 0 && memoryBytes / 1024 <= UInt64(UInt32.max) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "\(parameters.algorithm.displayName) KDF memory 无效；请确认文件未损坏。"
            )
        }
        guard parallelism > 0 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "\(parameters.algorithm.displayName) KDF parallelism 无效；请确认文件未损坏。"
            )
        }
        let version = argon2Parameters.version ?? UInt32(argon2.ARGON2_VERSION_13.rawValue)
        guard version == UInt32(argon2.ARGON2_VERSION_10.rawValue) || version == UInt32(argon2.ARGON2_VERSION_13.rawValue) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "\(parameters.algorithm.displayName) KDF version 不受支持；请确认文件未损坏。"
            )
        }

        let memoryKiB = UInt32(memoryBytes / 1024)
        let algorithmType: argon2_type
        switch parameters.algorithm {
        case .argon2d:
            algorithmType = Argon2_d
        case .argon2id:
            algorithmType = Argon2_id
        case .aesKdf, .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "\(parameters.algorithm.displayName) KDF 参数不匹配；请确认文件未损坏。"
            )
        }

        var output = Data(repeating: 0, count: 32)
        var password = context.credentialMaterial.compositeKey
        var saltBytes = salt
        let outputLength = output.count
        let passwordLength = password.count
        let saltLength = saltBytes.count
        let status = output.withUnsafeMutableBytes { outputBuffer in
            password.withUnsafeMutableBytes { passwordBuffer in
                saltBytes.withUnsafeMutableBytes { saltBuffer in
                    argon2_hash(
                        UInt32(iterations),
                        memoryKiB,
                        parallelism,
                        passwordBuffer.baseAddress,
                        passwordLength,
                        saltBuffer.baseAddress,
                        saltLength,
                        outputBuffer.baseAddress,
                        outputLength,
                        nil,
                        0,
                        algorithmType,
                        version
                    )
                }
            }
        }
        guard status == ARGON2_OK.rawValue else {
            throw KeePassOperationError(
                code: .invalidCredential,
                message: "\(parameters.algorithm.displayName) KDF 执行失败；请确认数据库密码、密钥文件或 KDF 参数。"
            )
        }

        return KeePassKdbxDerivedKey(
            algorithm: parameters.algorithm,
            material: output,
            rounds: nil
        )
    }
}

private enum KeePassAES256ECB {
    private static let blockSize = 16
    private static let rounds = 14

    static func encryptBlock(_ block: Data, key: Data) throws -> Data {
        guard block.count == blockSize else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX AES block 长度无效；请确认文件未损坏。"
            )
        }
        guard key.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX AES key 长度无效；请确认文件未损坏。"
            )
        }
        return Data(encryptBlock([UInt8](block), roundKeys: expandKey([UInt8](key))))
    }

    static func decryptBlock(_ block: Data, key: Data) throws -> Data {
        guard block.count == blockSize else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX AES block 长度无效；请确认文件未损坏。"
            )
        }
        guard key.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX AES key 长度无效；请确认文件未损坏。"
            )
        }
        return Data(decryptBlock([UInt8](block), roundKeys: expandKey([UInt8](key))))
    }

    static func transform(_ data: Data, key: Data, rounds: UInt64) throws -> Data {
        guard data.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX composite key 长度无效"
            )
        }
        let roundKeys = expandKey([UInt8](key))
        var output = [UInt8](data)
        for _ in 0..<rounds {
            var offset = 0
            while offset < output.count {
                let encrypted = encryptBlock(Array(output[offset..<offset + blockSize]), roundKeys: roundKeys)
                output.replaceSubrange(offset..<offset + blockSize, with: encrypted)
                offset += blockSize
            }
        }
        return Data(output)
    }

    private static func encryptBlock(_ block: [UInt8], roundKeys: [UInt8]) -> [UInt8] {
        var state = block
        addRoundKey(&state, roundKeys: roundKeys, round: 0)

        for round in 1..<rounds {
            subBytes(&state)
            shiftRows(&state)
            mixColumns(&state)
            addRoundKey(&state, roundKeys: roundKeys, round: round)
        }

        subBytes(&state)
        shiftRows(&state)
        addRoundKey(&state, roundKeys: roundKeys, round: rounds)
        return state
    }

    private static func decryptBlock(_ block: [UInt8], roundKeys: [UInt8]) -> [UInt8] {
        var state = block
        addRoundKey(&state, roundKeys: roundKeys, round: rounds)

        for round in stride(from: rounds - 1, through: 1, by: -1) {
            inverseShiftRows(&state)
            inverseSubBytes(&state)
            addRoundKey(&state, roundKeys: roundKeys, round: round)
            inverseMixColumns(&state)
        }

        inverseShiftRows(&state)
        inverseSubBytes(&state)
        addRoundKey(&state, roundKeys: roundKeys, round: 0)
        return state
    }

    private static func expandKey(_ key: [UInt8]) -> [UInt8] {
        let keyWords = 8
        let totalWords = 4 * (rounds + 1)
        var expanded = key
        expanded.reserveCapacity(totalWords * 4)

        var wordIndex = keyWords
        while wordIndex < totalWords {
            var temp = Array(expanded[(wordIndex - 1) * 4..<wordIndex * 4])
            if wordIndex.isMultiple(of: keyWords) {
                temp = subWord(rotWord(temp))
                temp[0] ^= rcon[(wordIndex / keyWords) - 1]
            } else if wordIndex % keyWords == 4 {
                temp = subWord(temp)
            }

            let base = (wordIndex - keyWords) * 4
            for index in 0..<4 {
                expanded.append(expanded[base + index] ^ temp[index])
            }
            wordIndex += 1
        }

        return expanded
    }

    private static func rotWord(_ word: [UInt8]) -> [UInt8] {
        [word[1], word[2], word[3], word[0]]
    }

    private static func subWord(_ word: [UInt8]) -> [UInt8] {
        word.map { sBox[Int($0)] }
    }

    private static func subBytes(_ state: inout [UInt8]) {
        for index in state.indices {
            state[index] = sBox[Int(state[index])]
        }
    }

    private static func shiftRows(_ state: inout [UInt8]) {
        let original = state
        state[1] = original[5]
        state[5] = original[9]
        state[9] = original[13]
        state[13] = original[1]

        state[2] = original[10]
        state[6] = original[14]
        state[10] = original[2]
        state[14] = original[6]

        state[3] = original[15]
        state[7] = original[3]
        state[11] = original[7]
        state[15] = original[11]
    }

    private static func mixColumns(_ state: inout [UInt8]) {
        for column in 0..<4 {
            let offset = column * 4
            let a0 = state[offset]
            let a1 = state[offset + 1]
            let a2 = state[offset + 2]
            let a3 = state[offset + 3]
            state[offset] = multiply2(a0) ^ multiply3(a1) ^ a2 ^ a3
            state[offset + 1] = a0 ^ multiply2(a1) ^ multiply3(a2) ^ a3
            state[offset + 2] = a0 ^ a1 ^ multiply2(a2) ^ multiply3(a3)
            state[offset + 3] = multiply3(a0) ^ a1 ^ a2 ^ multiply2(a3)
        }
    }

    private static func inverseSubBytes(_ state: inout [UInt8]) {
        for index in state.indices {
            state[index] = inverseSBox[Int(state[index])]
        }
    }

    private static func inverseShiftRows(_ state: inout [UInt8]) {
        let original = state
        state[1] = original[13]
        state[5] = original[1]
        state[9] = original[5]
        state[13] = original[9]

        state[2] = original[10]
        state[6] = original[14]
        state[10] = original[2]
        state[14] = original[6]

        state[3] = original[7]
        state[7] = original[11]
        state[11] = original[15]
        state[15] = original[3]
    }

    private static func inverseMixColumns(_ state: inout [UInt8]) {
        for column in 0..<4 {
            let offset = column * 4
            let a0 = state[offset]
            let a1 = state[offset + 1]
            let a2 = state[offset + 2]
            let a3 = state[offset + 3]
            state[offset] = multiply(0x0E, a0) ^ multiply(0x0B, a1) ^ multiply(0x0D, a2) ^ multiply(0x09, a3)
            state[offset + 1] = multiply(0x09, a0) ^ multiply(0x0E, a1) ^ multiply(0x0B, a2) ^ multiply(0x0D, a3)
            state[offset + 2] = multiply(0x0D, a0) ^ multiply(0x09, a1) ^ multiply(0x0E, a2) ^ multiply(0x0B, a3)
            state[offset + 3] = multiply(0x0B, a0) ^ multiply(0x0D, a1) ^ multiply(0x09, a2) ^ multiply(0x0E, a3)
        }
    }

    private static func addRoundKey(_ state: inout [UInt8], roundKeys: [UInt8], round: Int) {
        let offset = round * blockSize
        for index in 0..<blockSize {
            state[index] ^= roundKeys[offset + index]
        }
    }

    private static func multiply2(_ value: UInt8) -> UInt8 {
        let shifted = value << 1
        return value & 0x80 == 0 ? shifted : shifted ^ 0x1B
    }

    private static func multiply3(_ value: UInt8) -> UInt8 {
        multiply2(value) ^ value
    }

    private static func multiply(_ multiplier: UInt8, _ value: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var factor = multiplier
        var current = value
        while factor > 0 {
            if factor & 1 == 1 {
                result ^= current
            }
            current = multiply2(current)
            factor >>= 1
        }
        return result
    }

    private static let rcon: [UInt8] = [
        0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40
    ]

    private static let sBox: [UInt8] = [
        0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
        0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
        0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
        0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
        0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
        0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
        0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
        0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
        0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
        0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
        0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
        0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
        0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
        0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
        0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
        0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16
    ]

    private static let inverseSBox: [UInt8] = [
        0x52, 0x09, 0x6A, 0xD5, 0x30, 0x36, 0xA5, 0x38, 0xBF, 0x40, 0xA3, 0x9E, 0x81, 0xF3, 0xD7, 0xFB,
        0x7C, 0xE3, 0x39, 0x82, 0x9B, 0x2F, 0xFF, 0x87, 0x34, 0x8E, 0x43, 0x44, 0xC4, 0xDE, 0xE9, 0xCB,
        0x54, 0x7B, 0x94, 0x32, 0xA6, 0xC2, 0x23, 0x3D, 0xEE, 0x4C, 0x95, 0x0B, 0x42, 0xFA, 0xC3, 0x4E,
        0x08, 0x2E, 0xA1, 0x66, 0x28, 0xD9, 0x24, 0xB2, 0x76, 0x5B, 0xA2, 0x49, 0x6D, 0x8B, 0xD1, 0x25,
        0x72, 0xF8, 0xF6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xD4, 0xA4, 0x5C, 0xCC, 0x5D, 0x65, 0xB6, 0x92,
        0x6C, 0x70, 0x48, 0x50, 0xFD, 0xED, 0xB9, 0xDA, 0x5E, 0x15, 0x46, 0x57, 0xA7, 0x8D, 0x9D, 0x84,
        0x90, 0xD8, 0xAB, 0x00, 0x8C, 0xBC, 0xD3, 0x0A, 0xF7, 0xE4, 0x58, 0x05, 0xB8, 0xB3, 0x45, 0x06,
        0xD0, 0x2C, 0x1E, 0x8F, 0xCA, 0x3F, 0x0F, 0x02, 0xC1, 0xAF, 0xBD, 0x03, 0x01, 0x13, 0x8A, 0x6B,
        0x3A, 0x91, 0x11, 0x41, 0x4F, 0x67, 0xDC, 0xEA, 0x97, 0xF2, 0xCF, 0xCE, 0xF0, 0xB4, 0xE6, 0x73,
        0x96, 0xAC, 0x74, 0x22, 0xE7, 0xAD, 0x35, 0x85, 0xE2, 0xF9, 0x37, 0xE8, 0x1C, 0x75, 0xDF, 0x6E,
        0x47, 0xF1, 0x1A, 0x71, 0x1D, 0x29, 0xC5, 0x89, 0x6F, 0xB7, 0x62, 0x0E, 0xAA, 0x18, 0xBE, 0x1B,
        0xFC, 0x56, 0x3E, 0x4B, 0xC6, 0xD2, 0x79, 0x20, 0x9A, 0xDB, 0xC0, 0xFE, 0x78, 0xCD, 0x5A, 0xF4,
        0x1F, 0xDD, 0xA8, 0x33, 0x88, 0x07, 0xC7, 0x31, 0xB1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xEC, 0x5F,
        0x60, 0x51, 0x7F, 0xA9, 0x19, 0xB5, 0x4A, 0x0D, 0x2D, 0xE5, 0x7A, 0x9F, 0x93, 0xC9, 0x9C, 0xEF,
        0xA0, 0xE0, 0x3B, 0x4D, 0xAE, 0x2A, 0xF5, 0xB0, 0xC8, 0xEB, 0xBB, 0x3C, 0x83, 0x53, 0x99, 0x61,
        0x17, 0x2B, 0x04, 0x7E, 0xBA, 0x77, 0xD6, 0x26, 0xE1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0C, 0x7D
    ]
}

private enum KeePassAES256CBC {
    private static let blockSize = 16

    static func encrypt(_ data: Data, key: Data, iv: Data?) throws -> Data {
        guard key.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX AES master key 长度无效；请确认文件未损坏。"
            )
        }
        guard let iv, iv.count == blockSize else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX AES IV 缺失或长度无效；请确认文件未损坏。"
            )
        }

        let padded = data.addingPKCS7Padding(blockSize: blockSize)
        var output = Data()
        output.reserveCapacity(padded.count)
        var previousBlock = iv
        var offset = 0
        while offset < padded.count {
            var plainBlock = Data(padded[offset..<offset + blockSize])
            for index in 0..<blockSize {
                plainBlock[index] ^= previousBlock[index]
            }
            let encryptedBlock = try KeePassAES256ECB.encryptBlock(plainBlock, key: key)
            output.append(encryptedBlock)
            previousBlock = encryptedBlock
            offset += blockSize
        }
        return output
    }

    static func decrypt(_ data: Data, key: Data, iv: Data?) throws -> Data {
        guard key.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX AES master key 长度无效；请确认文件未损坏。"
            )
        }
        guard let iv, iv.count == blockSize else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX AES IV 缺失或长度无效；请确认文件未损坏。"
            )
        }
        guard !data.isEmpty, data.count.isMultiple(of: blockSize) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX AES payload 长度无效；请确认文件未损坏。"
            )
        }

        var output = Data()
        output.reserveCapacity(data.count)
        var previousBlock = iv
        var offset = 0
        while offset < data.count {
            let encryptedBlock = Data(data[offset..<offset + blockSize])
            var decryptedBlock = try KeePassAES256ECB.decryptBlock(encryptedBlock, key: key)
            for index in 0..<blockSize {
                decryptedBlock[index] ^= previousBlock[index]
            }
            output.append(decryptedBlock)
            previousBlock = encryptedBlock
            offset += blockSize
        }
        return output.removingPKCS7Padding(blockSize: blockSize)
    }
}

private enum KeePassTwofishCBC {
    private static let blockSize = 16

    static func encrypt(_ data: Data, key: Data, iv: Data?) throws -> Data {
        guard key.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX Twofish master key 长度无效；请确认写回参数完整。"
            )
        }
        guard let iv, iv.count == blockSize else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX Twofish IV 缺失或长度无效；请确认写回参数完整。"
            )
        }
        let padded = data.addingPKCS7Padding(blockSize: blockSize)
        var output = Data(repeating: 0, count: padded.count)
        let status = output.withUnsafeMutableBytes { outputBuffer in
            padded.withUnsafeBytes { dataBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        monica_twofish_encrypt_cbc(
                            keyBuffer.bindMemory(to: UInt8.self).baseAddress,
                            key.count,
                            ivBuffer.bindMemory(to: UInt8.self).baseAddress,
                            iv.count,
                            dataBuffer.bindMemory(to: UInt8.self).baseAddress,
                            padded.count,
                            outputBuffer.bindMemory(to: UInt8.self).baseAddress
                        )
                    }
                }
            }
        }
        guard status == 1 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX Twofish payload 加密失败；请确认写回参数完整。"
            )
        }
        return output
    }

    static func decrypt(_ data: Data, key: Data, iv: Data?) throws -> Data {
        guard key.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX Twofish master key 长度无效；请确认文件未损坏。"
            )
        }
        guard let iv, iv.count == blockSize else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX Twofish IV 缺失或长度无效；请确认文件未损坏。"
            )
        }
        guard !data.isEmpty, data.count.isMultiple(of: blockSize) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX Twofish payload 长度无效；请确认文件未损坏。"
            )
        }

        var output = Data(repeating: 0, count: data.count)
        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { dataBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        monica_twofish_decrypt_cbc(
                            keyBuffer.bindMemory(to: UInt8.self).baseAddress,
                            key.count,
                            ivBuffer.bindMemory(to: UInt8.self).baseAddress,
                            iv.count,
                            dataBuffer.bindMemory(to: UInt8.self).baseAddress,
                            data.count,
                            outputBuffer.bindMemory(to: UInt8.self).baseAddress
                        )
                    }
                }
            }
        }
        guard status == 1 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX Twofish payload 解密失败；请确认文件未损坏。"
            )
        }
        return output.removingPKCS7Padding(blockSize: blockSize)
    }
}

private extension Data {
    func addingPKCS7Padding(blockSize: Int) -> Data {
        let paddingLength = blockSize - (count % blockSize)
        var output = self
        output.append(contentsOf: repeatElement(UInt8(paddingLength), count: paddingLength))
        return output
    }

    func removingPKCS7Padding(blockSize: Int) -> Data {
        guard let lastByte = self.last else {
            return self
        }
        let paddingLength = Int(lastByte)
        guard paddingLength > 0,
              paddingLength <= blockSize,
              paddingLength <= count else {
            return self
        }
        let paddingStart = count - paddingLength
        guard self[paddingStart..<count].allSatisfy({ $0 == lastByte }) else {
            return self
        }
        return Data(self[0..<paddingStart])
    }
}

public struct KeePassCredentialSummary: Sendable, Equatable {
    public let hasPassword: Bool
    public let hasKeyFile: Bool
    public let keyFileName: String?
    public let keyFileCandidateCount: Int

    public init(
        hasPassword: Bool,
        hasKeyFile: Bool,
        keyFileName: String?,
        keyFileCandidateCount: Int = 0
    ) {
        self.hasPassword = hasPassword
        self.hasKeyFile = hasKeyFile
        self.keyFileName = keyFileName
        self.keyFileCandidateCount = keyFileCandidateCount
    }

    public var displayName: String {
        switch (hasPassword, hasKeyFile) {
        case (true, true):
            let count = keyFileCandidateCount > 0 ? "（\(keyFileCandidateCount) 种 key 解析）" : ""
            return "密码 + 密钥文件\(count)"
        case (true, false):
            return "密码"
        case (false, true):
            let count = keyFileCandidateCount > 0 ? "（\(keyFileCandidateCount) 种 key 解析）" : ""
            return "密钥文件\(count)"
        case (false, false):
            return "未提供凭据"
        }
    }
}

public enum KeePassErrorCode: Sendable, Equatable {
    case legacyKdbUnsupported
    case formatUnsupported
    case invalidCredential
    case uriPermissionDenied
    case kdfMemoryInsufficient
    case ioReadWriteFailed
}

public struct KeePassImportIssue: Sendable, Equatable {
    public let code: KeePassErrorCode
    public let message: String

    public init(code: KeePassErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct KeePassImportPreviewReport: Sendable, Equatable {
    public let format: KeePassContainerFormat
    public let status: KeePassImportStatus
    public let sourceName: String?
    public let headerSummary: KeePassHeaderSummary?
    public let issue: KeePassImportIssue?

    public init(
        format: KeePassContainerFormat,
        status: KeePassImportStatus,
        sourceName: String?,
        headerSummary: KeePassHeaderSummary?,
        issue: KeePassImportIssue?
    ) {
        self.format = format
        self.status = status
        self.sourceName = sourceName
        self.headerSummary = headerSummary
        self.issue = issue
    }
}

public struct KeePassUnlockPreflightReport: Sendable, Equatable {
    public let format: KeePassContainerFormat
    public let status: KeePassImportStatus
    public let sourceName: String?
    public let headerSummary: KeePassHeaderSummary?
    public let credentials: KeePassCredentialSummary
    public let issue: KeePassImportIssue?

    public init(
        format: KeePassContainerFormat,
        status: KeePassImportStatus,
        sourceName: String?,
        headerSummary: KeePassHeaderSummary?,
        credentials: KeePassCredentialSummary,
        issue: KeePassImportIssue?
    ) {
        self.format = format
        self.status = status
        self.sourceName = sourceName
        self.headerSummary = headerSummary
        self.credentials = credentials
        self.issue = issue
    }
}

public struct KeePassUnlockCredentials: Sendable, Equatable {
    public let password: String
    public let keyFile: Data?
    public let keyFileName: String?
    public let candidateLabel: String?

    public init(
        password: String,
        keyFile: Data?,
        keyFileName: String?,
        candidateLabel: String? = nil
    ) {
        self.password = password
        self.keyFile = keyFile
        self.keyFileName = keyFileName?.sanitizedKeePassFileName
        self.candidateLabel = candidateLabel
    }

    public var hasPassword: Bool {
        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasKeyFile: Bool {
        keyFile?.isEmpty == false
    }

    public var summary: KeePassCredentialSummary {
        KeePassCredentialSummary(
            hasPassword: hasPassword,
            hasKeyFile: hasKeyFile,
            keyFileName: keyFileName,
            keyFileCandidateCount: credentialCandidates.count
        )
    }

    public var credentialCandidates: [KeePassCredentialCandidate] {
        KeePassCredentialSupport.buildCredentialCandidates(password: password, keyFile: keyFile)
    }
}

public struct KeePassCredentialCandidate: Sendable, Equatable, Identifiable {
    public let label: String
    public let password: String
    public let keyMaterial: Data?

    public var id: String {
        label
    }

    public init(label: String, password: String, keyMaterial: Data?) {
        self.label = label
        self.password = password
        self.keyMaterial = keyMaterial
    }
}

public struct KeePassKeyFileMaterial: Sendable, Equatable, Identifiable {
    public let label: String
    public let key: Data

    public var id: String {
        label
    }

    public init(label: String, key: Data) {
        self.label = label
        self.key = key
    }

    public static func buildVariants(from rawBytes: Data) -> [KeePassKeyFileMaterial] {
        var variants: [KeePassKeyFileMaterial] = []
        var seenHashes = Set<String>()

        func append(_ label: String, _ key: Data?) {
            guard let key, !key.isEmpty else { return }
            let hash = KeePassCredentialSupport.sha256Hex(key)
            guard seenHashes.insert(hash).inserted else { return }
            variants.append(KeePassKeyFileMaterial(label: label, key: key))
        }

        append("raw", rawBytes)
        if let text = String(data: rawBytes, encoding: .utf8) {
            append("xml-data", xmlDataKey(from: text))
            append("hex-text", hexTextKey(from: text))
        }
        append("sha256(raw)", Data(SHA256.hash(data: rawBytes)))
        return variants
    }

    private static func xmlDataKey(from content: String) -> Data? {
        guard let startRange = content.range(of: "<Data", options: [.caseInsensitive]),
              let startClose = content[startRange.upperBound...].firstIndex(of: ">"),
              let endRange = content[startClose...].range(of: "</Data>", options: [.caseInsensitive]) else {
            return nil
        }
        let rawValue = content[content.index(after: startClose)..<endRange.lowerBound]
        let compact = rawValue.filter { !$0.isWhitespace }
        return decodeCompactKeyData(String(compact))
    }

    private static func hexTextKey(from content: String) -> Data? {
        let compact = String(content.filter { !$0.isWhitespace })
        guard compact.count == 64, compact.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return decodeHex(compact)
    }

    private static func decodeCompactKeyData(_ compact: String) -> Data? {
        if compact.count == 64, compact.allSatisfy(\.isHexDigit) {
            return decodeHex(compact)
        }
        return Data(base64Encoded: compact)
    }

    private static func decodeHex(_ value: String) -> Data? {
        guard value.count.isMultiple(of: 2),
              value.allSatisfy(\.isHexDigit) else {
            return nil
        }
        var output = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                return nil
            }
            output.append(byte)
            index = next
        }
        return output
    }
}

public enum KeePassCredentialSupport {
    public static func buildCredentialCandidates(
        password: String,
        keyFile: Data?
    ) -> [KeePassCredentialCandidate] {
        guard let keyFile, !keyFile.isEmpty else {
            return [
                KeePassCredentialCandidate(
                    label: "password-only",
                    password: password,
                    keyMaterial: nil
                )
            ]
        }

        var candidates: [KeePassCredentialCandidate] = []
        var seen = Set<String>()
        let materials = KeePassKeyFileMaterial.buildVariants(from: keyFile)

        func append(label: String, password: String, key: Data?) {
            let keySignature = key.map(sha256Hex) ?? "no-key"
            let signature = "\(label):\(keySignature):\(password.count)"
            guard seen.insert(signature).inserted else { return }
            candidates.append(
                KeePassCredentialCandidate(
                    label: label,
                    password: password,
                    keyMaterial: key
                )
            )
        }

        if !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append(label: "password-only", password: password, key: nil)
        }
        for material in materials {
            if password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                append(label: "\(material.label)/key-only", password: "", key: material.key)
                append(label: "\(material.label)/empty-password+key", password: "", key: material.key)
            } else {
                append(label: "\(material.label)/password+key", password: password, key: material.key)
            }
        }

        return candidates
    }

    public static func invalidCredentialMessage(attemptedLabels: [String]) -> String {
        var seen = Set<String>()
        let distinct = attemptedLabels.filter { seen.insert($0).inserted }
        guard !distinct.isEmpty else {
            return "数据库密码或密钥文件不正确"
        }
        let concise = distinct.prefix(4).joined(separator: ", ")
        let suffix = distinct.count > 4 ? " 等\(distinct.count)种组合" : ""
        return "数据库密码或密钥文件不正确（已尝试: \(concise)\(suffix)）"
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct KeePassReadOnlyGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let path: String
    public let depth: Int

    public init(id: String, title: String, path: String, depth: Int) {
        self.id = id
        self.title = title
        self.path = path
        self.depth = depth
    }
}

public struct KeePassReadOnlyAttachment: Sendable, Equatable, Identifiable {
    public let id: String
    public let fileName: String
    public let mediaType: String
    public let originalSize: Int64
    public let contentHash: String
    public let decodedContent: Data?

    public init(
        id: String,
        fileName: String,
        mediaType: String = "application/octet-stream",
        originalSize: Int64 = 0,
        contentHash: String = "",
        decodedContent: Data? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.mediaType = mediaType
        self.originalSize = originalSize
        self.contentHash = contentHash
        self.decodedContent = decodedContent
    }
}

public struct KeePassReadOnlyTotpSecret: Sendable, Equatable {
    public let secret: String
    public let issuer: String?
    public let accountName: String?
    public let period: UInt32?
    public let digits: UInt32?
    public let algorithm: String?

    public init(
        secret: String,
        issuer: String? = nil,
        accountName: String? = nil,
        period: UInt32? = nil,
        digits: UInt32? = nil,
        algorithm: String? = nil
    ) {
        self.secret = secret
        self.issuer = issuer
        self.accountName = accountName
        self.period = period
        self.digits = digits
        self.algorithm = algorithm
    }
}

public struct KeePassReadOnlyCustomField: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let value: String
    public let isProtected: Bool
    public let sortOrder: Int

    public init(
        title: String,
        value: String,
        isProtected: Bool,
        sortOrder: Int = 0
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmedTitle
        self.value = value
        self.isProtected = isProtected
        self.sortOrder = sortOrder
        self.id = "\(sortOrder):\(trimmedTitle)"
    }
}

public struct KeePassReadOnlyEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let username: String
    public let url: String
    public let groupPath: String
    public let groupID: String?
    public let notes: String
    public let customFields: [KeePassReadOnlyCustomField]
    public let hasPassword: Bool
    public let hasTotp: Bool
    public let attachmentCount: Int
    public let isDeleted: Bool
    public let decodedPassword: String?
    public let decodedTotp: KeePassReadOnlyTotpSecret?
    public let attachments: [KeePassReadOnlyAttachment]

    public init(
        id: String,
        title: String,
        username: String,
        url: String,
        groupPath: String,
        groupID: String? = nil,
        notes: String = "",
        customFields: [KeePassReadOnlyCustomField] = [],
        hasPassword: Bool,
        decodedPassword: String? = nil,
        hasTotp: Bool,
        decodedTotp: KeePassReadOnlyTotpSecret? = nil,
        attachmentCount: Int,
        isDeleted: Bool,
        attachments: [KeePassReadOnlyAttachment] = []
    ) {
        self.id = id
        self.title = title
        self.username = username
        self.url = url
        self.groupPath = groupPath
        self.groupID = groupID
        self.notes = notes
        self.customFields = customFields
            .filter { !$0.title.isEmpty }
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.sortOrder < rhs.sortOrder
            }
        self.hasPassword = hasPassword
        self.hasTotp = hasTotp
        self.attachmentCount = max(attachmentCount, attachments.count)
        self.isDeleted = isDeleted
        self.decodedPassword = decodedPassword
        self.decodedTotp = decodedTotp
        self.attachments = attachments
    }
}

public struct KeePassReadOnlySnapshot: Sendable, Equatable {
    public let sourceName: String?
    public let headerSummary: KeePassHeaderSummary?
    public let groups: [KeePassReadOnlyGroup]
    public let entries: [KeePassReadOnlyEntry]

    public init(
        sourceName: String?,
        headerSummary: KeePassHeaderSummary?,
        groups: [KeePassReadOnlyGroup],
        entries: [KeePassReadOnlyEntry]
    ) {
        self.sourceName = sourceName
        self.headerSummary = headerSummary
        self.groups = groups
        self.entries = entries
    }

    public var groupCount: Int {
        groups.count
    }

    public var entryCount: Int {
        entries.count
    }

    public var displaySummary: String {
        let version = headerSummary?.displayName ?? "KDBX"
        return "\(version)，\(groupCount) 个分组，\(entryCount) 个条目"
    }
}

public struct KeePassXMLWritebackPayload: Sendable, Equatable {
    public let xmlPayload: Data
    public let binaryContents: [Data]
    public let groupCount: Int
    public let entryCount: Int
    public let attachmentCount: Int

    public init(
        xmlPayload: Data,
        binaryContents: [Data] = [],
        groupCount: Int,
        entryCount: Int,
        attachmentCount: Int
    ) {
        self.xmlPayload = xmlPayload
        self.binaryContents = binaryContents
        self.groupCount = groupCount
        self.entryCount = entryCount
        self.attachmentCount = attachmentCount
    }

    public var displaySummary: String {
        "KeePass XML writeback payload，\(groupCount) 个分组，\(entryCount) 个条目，\(attachmentCount) 个附件"
    }
}

public enum KeePassXMLProtectedValueWritebackMode: Sendable, Equatable {
    case preserveProtectedAttributes
    case writePlainValues
    case encryptProtectedValues(KeePassKdbxPayloadCryptoInputs)
}

public enum KeePassXMLBinaryWritebackMode: Sendable, Equatable {
    case inlineMetaBinaries
    case externalReferences
}

public struct KeePassXMLPayloadWriter: Sendable {
    private let protectedValueMode: KeePassXMLProtectedValueWritebackMode
    private let binaryMode: KeePassXMLBinaryWritebackMode

    public init(
        protectedValueMode: KeePassXMLProtectedValueWritebackMode = .preserveProtectedAttributes,
        binaryMode: KeePassXMLBinaryWritebackMode = .inlineMetaBinaries
    ) {
        self.protectedValueMode = protectedValueMode
        self.binaryMode = binaryMode
    }

    public func write(_ snapshot: KeePassReadOnlySnapshot) throws -> KeePassXMLWritebackPayload {
        let tree = KeePassXMLWritebackTree(snapshot: snapshot)
        var binaries: [(id: String, content: Data)] = []
        var binaryRefsByEntryAttachment: [KeePassXMLWritebackAttachmentKey: String] = [:]
        var xml: [String] = [
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
            "<KeePassFile>",
            "  <Meta>"
        ]
        if let recycleBinUUID = tree.recycleBinUUID {
            xml.append("    <RecycleBinUUID>\(Self.escapeText(recycleBinUUID))</RecycleBinUUID>")
        }
        xml.append("    <Binaries>")
        for entry in snapshot.entries {
            for (index, attachment) in entry.attachments.enumerated() {
                guard let content = attachment.decodedContent else {
                    throw KeePassOperationError(
                        code: .formatUnsupported,
                        message: "KeePass XML 写回需要已解码的附件内容；请先完成附件解码。"
                    )
                }
                let id = binaryMode == .externalReferences
                    ? "\(binaries.count)"
                    : Self.uniqueBinaryID(preferred: attachment.id, existing: Set(binaries.map(\.id)))
                binaryRefsByEntryAttachment[
                    KeePassXMLWritebackAttachmentKey(entryID: entry.id, attachmentIndex: index)
                ] = id
                binaries.append((id: id, content: content))
                if binaryMode == .inlineMetaBinaries {
                    xml.append("      <Binary ID=\"\(Self.escapeAttribute(id))\">\(content.base64EncodedString())</Binary>")
                }
            }
        }
        xml.append("    </Binaries>")
        xml.append("  </Meta>")
        let protectedValueEncoder = try protectedValueEncoder()
        xml.append("  <Root>")
        appendGroup(
            tree.root,
            into: &xml,
            binaryRefsByEntryAttachment: binaryRefsByEntryAttachment,
            protectedValueEncoder: protectedValueEncoder,
            indent: "    "
        )
        xml.append("  </Root>")
        xml.append("</KeePassFile>")
        let payload = Data(xml.joined(separator: "\n").utf8)
        return KeePassXMLWritebackPayload(
            xmlPayload: payload,
            binaryContents: binaries.map(\.content),
            groupCount: snapshot.groups.count,
            entryCount: snapshot.entries.count,
            attachmentCount: binaries.count
        )
    }

    private func appendGroup(
        _ node: KeePassXMLWritebackTree.Node,
        into xml: inout [String],
        binaryRefsByEntryAttachment: [KeePassXMLWritebackAttachmentKey: String],
        protectedValueEncoder: KeePassProtectedValueStreamEncoder?,
        indent: String
    ) {
        xml.append("\(indent)<Group>")
        xml.append("\(indent)  <UUID>\(Self.escapeText(node.group.id))</UUID>")
        xml.append("\(indent)  <Name>\(Self.escapeText(node.group.title))</Name>")
        for entry in node.entries {
            appendEntry(
                entry,
                into: &xml,
                binaryRefsByEntryAttachment: binaryRefsByEntryAttachment,
                protectedValueEncoder: protectedValueEncoder,
                indent: indent + "  "
            )
        }
        for child in node.children {
            appendGroup(
                child,
                into: &xml,
                binaryRefsByEntryAttachment: binaryRefsByEntryAttachment,
                protectedValueEncoder: protectedValueEncoder,
                indent: indent + "  "
            )
        }
        xml.append("\(indent)</Group>")
    }

    private func appendEntry(
        _ entry: KeePassReadOnlyEntry,
        into xml: inout [String],
        binaryRefsByEntryAttachment: [KeePassXMLWritebackAttachmentKey: String],
        protectedValueEncoder: KeePassProtectedValueStreamEncoder?,
        indent: String
    ) {
        xml.append("\(indent)<Entry>")
        xml.append("\(indent)  <UUID>\(Self.escapeText(entry.id))</UUID>")
        appendString(key: "Title", value: entry.title, into: &xml, indent: indent + "  ")
        appendString(key: "UserName", value: entry.username, into: &xml, indent: indent + "  ")
        appendString(
            key: "Password",
            value: entry.decodedPassword ?? "",
            isProtected: shouldMarkProtected(entry.hasPassword),
            protectedValueEncoder: protectedValueEncoder,
            into: &xml,
            indent: indent + "  "
        )
        appendString(key: "URL", value: entry.url, into: &xml, indent: indent + "  ")
        appendString(key: "Notes", value: entry.notes, into: &xml, indent: indent + "  ")
        if let decodedTotp = entry.decodedTotp {
            appendString(
                key: "otp",
                value: Self.otpAuthURI(from: decodedTotp, fallbackTitle: entry.title),
                isProtected: shouldMarkProtected(true),
                protectedValueEncoder: protectedValueEncoder,
                into: &xml,
                indent: indent + "  "
            )
        }
        for field in entry.customFields {
            appendString(
                key: field.title,
                value: field.value,
                isProtected: shouldMarkProtected(field.isProtected),
                protectedValueEncoder: protectedValueEncoder,
                into: &xml,
                indent: indent + "  "
            )
        }
        for (index, attachment) in entry.attachments.enumerated() {
            let ref = binaryRefsByEntryAttachment[
                KeePassXMLWritebackAttachmentKey(entryID: entry.id, attachmentIndex: index)
            ] ?? attachment.id
            xml.append("\(indent)  <Binary>")
            xml.append("\(indent)    <Key>\(Self.escapeText(attachment.fileName))</Key>")
            xml.append("\(indent)    <Value Ref=\"\(Self.escapeAttribute(ref))\" />")
            xml.append("\(indent)  </Binary>")
        }
        xml.append("\(indent)</Entry>")
    }

    private func appendString(
        key: String,
        value: String,
        isProtected: Bool = false,
        protectedValueEncoder: KeePassProtectedValueStreamEncoder? = nil,
        into xml: inout [String],
        indent: String
    ) {
        xml.append("\(indent)<String>")
        xml.append("\(indent)  <Key>\(Self.escapeText(key))</Key>")
        if isProtected {
            let encodedValue = protectedValueEncoder?.encode(value) ?? value
            xml.append("\(indent)  <Value Protected=\"True\">\(Self.escapeText(encodedValue))</Value>")
        } else {
            xml.append("\(indent)  <Value>\(Self.escapeText(value))</Value>")
        }
        xml.append("\(indent)</String>")
    }

    private func shouldMarkProtected(_ isProtected: Bool) -> Bool {
        switch protectedValueMode {
        case .preserveProtectedAttributes:
            return isProtected
        case .writePlainValues:
            return false
        case .encryptProtectedValues:
            return isProtected
        }
    }

    private func protectedValueEncoder() throws -> KeePassProtectedValueStreamEncoder? {
        switch protectedValueMode {
        case .preserveProtectedAttributes, .writePlainValues:
            return nil
        case .encryptProtectedValues(let cryptoInputs):
            guard let encoder = try KeePassProtectedValueStreamEncoder.make(from: cryptoInputs) else {
                throw KeePassOperationError(
                    code: .formatUnsupported,
                    message: "KeePass protected value 写回需要 inner stream 参数；请确认写回参数完整。"
                )
            }
            return encoder
        }
    }

    private static func uniqueBinaryID(preferred: String, existing: Set<String>) -> String {
        let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !existing.contains(trimmed) {
            return trimmed
        }
        var candidate = "\(existing.count)"
        while existing.contains(candidate) {
            candidate = "\(Int(candidate).map { $0 + 1 } ?? existing.count + 1)"
        }
        return candidate
    }

    private static func otpAuthURI(from secret: KeePassReadOnlyTotpSecret, fallbackTitle: String) -> String {
        let issuer = secret.issuer ?? fallbackTitle
        let account = secret.accountName ?? ""
        let label = account.isEmpty ? issuer : "\(issuer):\(account)"
        var query = [("secret", secret.secret)]
        if let issuer = secret.issuer, !issuer.isEmpty {
            query.append(("issuer", issuer))
        }
        if let period = secret.period {
            query.append(("period", "\(period)"))
        }
        if let digits = secret.digits {
            query.append(("digits", "\(digits)"))
        }
        if let algorithm = secret.algorithm, !algorithm.isEmpty {
            query.append(("algorithm", algorithm.uppercased()))
        }
        return "otpauth://totp/\(percentEncode(label))?"
            + query.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
    }

    private static func escapeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escapeText(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct KeePassXMLWritebackTree {
    final class Node {
        let group: KeePassReadOnlyGroup
        var children: [Node] = []
        var entries: [KeePassReadOnlyEntry] = []

        init(group: KeePassReadOnlyGroup) {
            self.group = group
        }
    }

    let root: Node
    let recycleBinUUID: String?

    init(snapshot: KeePassReadOnlySnapshot) {
        let rootGroup = snapshot.groups.first { $0.path == "/" }
            ?? KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0)
        var nodesByPath: [String: Node] = ["/": Node(group: rootGroup)]
        for group in snapshot.groups where group.path != "/" {
            nodesByPath[group.path] = Node(group: group)
        }
        for group in snapshot.groups where group.path != "/" {
            let parentPath = Self.parentPath(for: group.path)
            let parent = nodesByPath[parentPath] ?? nodesByPath["/"]
            if let child = nodesByPath[group.path] {
                parent?.children.append(child)
            }
        }
        for entry in snapshot.entries {
            let path = entry.groupPath.isEmpty ? "/" : entry.groupPath
            let node = nodesByPath[path] ?? nodesByPath["/"]
            node?.entries.append(entry)
        }
        self.root = nodesByPath["/"] ?? Node(group: rootGroup)
        self.recycleBinUUID = Self.recycleBinUUID(in: snapshot)
    }

    private static func parentPath(for path: String) -> String {
        let normalized = path.hasPrefix("/") ? path : "/" + path
        guard normalized != "/" else { return "/" }
        let components = normalized.split(separator: "/").map(String.init)
        guard components.count > 1 else { return "/" }
        return "/" + components.dropLast().joined(separator: "/")
    }

    private static func recycleBinUUID(in snapshot: KeePassReadOnlySnapshot) -> String? {
        if let deletedGroupID = snapshot.entries.first(where: \.isDeleted)?.groupID,
           !deletedGroupID.isEmpty {
            return deletedGroupID
        }
        return snapshot.groups.first {
            $0.path.localizedCaseInsensitiveContains("recycle bin")
                || $0.title.localizedCaseInsensitiveContains("recycle bin")
        }?.id
    }
}

private struct KeePassXMLWritebackAttachmentKey: Hashable {
    let entryID: String
    let attachmentIndex: Int
}

public enum KeePassReadOnlyImportCandidateKind: Sendable, Equatable {
    case login

    public var displayName: String {
        switch self {
        case .login:
            return "密码条目"
        }
    }
}

public enum KeePassReadOnlyImportSkipReason: Sendable, Equatable {
    case deletedEntry

    public var displayName: String {
        switch self {
        case .deletedEntry:
            return "回收站条目"
        }
    }
}

public struct KeePassReadOnlyImportCandidate: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: KeePassReadOnlyImportCandidateKind
    public let title: String
    public let username: String
    public let url: String
    public let groupPath: String
    public let groupID: String?
    public let notes: String
    public let customFields: [KeePassReadOnlyCustomField]
    public let hasPassword: Bool
    public let hasTotp: Bool
    public let attachmentCount: Int
    public let isDeleted: Bool
    public let decodedPassword: String?
    public let decodedTotp: KeePassReadOnlyTotpSecret?
    public let attachments: [KeePassReadOnlyAttachment]

    public init(
        id: String,
        kind: KeePassReadOnlyImportCandidateKind,
        title: String,
        username: String,
        url: String,
        groupPath: String,
        groupID: String? = nil,
        notes: String = "",
        customFields: [KeePassReadOnlyCustomField] = [],
        hasPassword: Bool,
        decodedPassword: String? = nil,
        hasTotp: Bool,
        decodedTotp: KeePassReadOnlyTotpSecret? = nil,
        attachmentCount: Int,
        isDeleted: Bool = false,
        attachments: [KeePassReadOnlyAttachment] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.username = username
        self.url = url
        self.groupPath = groupPath
        self.groupID = groupID
        self.notes = notes
        self.customFields = customFields
            .filter { !$0.title.isEmpty }
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.sortOrder < rhs.sortOrder
            }
        self.hasPassword = hasPassword
        self.hasTotp = hasTotp
        self.attachmentCount = max(attachmentCount, attachments.count)
        self.isDeleted = isDeleted
        self.decodedPassword = decodedPassword
        self.decodedTotp = decodedTotp
        self.attachments = attachments
    }
}

public struct KeePassReadOnlyImportSkippedEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let groupPath: String
    public let groupID: String?
    public let reason: KeePassReadOnlyImportSkipReason

    public init(
        id: String,
        title: String,
        groupPath: String,
        groupID: String? = nil,
        reason: KeePassReadOnlyImportSkipReason
    ) {
        self.id = id
        self.title = title
        self.groupPath = groupPath
        self.groupID = groupID
        self.reason = reason
    }
}

public struct KeePassReadOnlyImportPlan: Sendable, Equatable {
    public let sourceName: String?
    public let headerSummary: KeePassHeaderSummary?
    public let candidates: [KeePassReadOnlyImportCandidate]
    public let skipped: [KeePassReadOnlyImportSkippedEntry]

    public init(
        sourceName: String?,
        headerSummary: KeePassHeaderSummary?,
        candidates: [KeePassReadOnlyImportCandidate],
        skipped: [KeePassReadOnlyImportSkippedEntry]
    ) {
        self.sourceName = sourceName
        self.headerSummary = headerSummary
        self.candidates = candidates
        self.skipped = skipped
    }

    public var candidateCount: Int {
        candidates.count
    }

    public var skippedCount: Int {
        skipped.count
    }

    public var deletedCandidateCount: Int {
        candidates.filter(\.isDeleted).count
    }

    public var pendingPasswordCount: Int {
        candidates.filter { $0.hasPassword && $0.decodedPassword == nil }.count
    }

    public var pendingTotpCount: Int {
        candidates.filter { $0.hasTotp && $0.decodedTotp == nil }.count
    }

    public var pendingAttachmentCount: Int {
        candidates.reduce(0) { total, candidate in
            let unknownAttachmentCount = max(candidate.attachmentCount - candidate.attachments.count, 0)
            let pendingKnownAttachmentCount = candidate.attachments.filter { $0.decodedContent == nil }.count
            return total + unknownAttachmentCount + pendingKnownAttachmentCount
        }
    }

    public var pendingCapabilitySummary: String {
        var parts: [String] = []
        if pendingPasswordCount > 0 {
            parts.append("\(pendingPasswordCount) 个密码字段")
        }
        if pendingTotpCount > 0 {
            parts.append("\(pendingTotpCount) 个 TOTP")
        }
        if pendingAttachmentCount > 0 {
            parts.append("\(pendingAttachmentCount) 个附件")
        }
        guard !parts.isEmpty else {
            return ""
        }
        return "待解码：\(parts.joined(separator: "，"))"
    }

    public var displaySummary: String {
        let version = headerSummary?.displayName ?? "KDBX"
        return "\(version)，\(candidateCount) 个可预览条目，\(skippedCount) 个跳过"
    }
}

public enum KeePassReadOnlyImportPlanner {
    public static func plan(_ snapshot: KeePassReadOnlySnapshot) -> KeePassReadOnlyImportPlan {
        var candidates: [KeePassReadOnlyImportCandidate] = []
        let skipped: [KeePassReadOnlyImportSkippedEntry] = []

        for entry in snapshot.entries {
            candidates.append(
                KeePassReadOnlyImportCandidate(
                    id: entry.id,
                    kind: .login,
                    title: entry.title,
                    username: entry.username,
                    url: entry.url,
                    groupPath: entry.groupPath,
                    groupID: entry.groupID,
                    notes: entry.notes,
                    customFields: entry.customFields,
                    hasPassword: entry.hasPassword,
                    decodedPassword: entry.decodedPassword,
                    hasTotp: entry.hasTotp,
                    decodedTotp: entry.decodedTotp,
                    attachmentCount: entry.attachmentCount,
                    isDeleted: entry.isDeleted,
                    attachments: entry.attachments
                )
            )
        }

        return KeePassReadOnlyImportPlan(
            sourceName: snapshot.sourceName,
            headerSummary: snapshot.headerSummary,
            candidates: candidates,
            skipped: skipped
        )
    }
}

public protocol KeePassDatabaseReader: Sendable {
    func readSnapshot(
        database: Data,
        sourceName: String?,
        credentials: KeePassUnlockCredentials
    ) throws -> KeePassReadOnlySnapshot
}

public struct KeePassCandidateTryingDatabaseReader: KeePassDatabaseReader {
    private let baseReader: any KeePassDatabaseReader

    public init(baseReader: any KeePassDatabaseReader) {
        self.baseReader = baseReader
    }

    public func readSnapshot(
        database: Data,
        sourceName: String?,
        credentials: KeePassUnlockCredentials
    ) throws -> KeePassReadOnlySnapshot {
        let candidates = credentials.credentialCandidates
        guard !candidates.isEmpty else {
            return try baseReader.readSnapshot(
                database: database,
                sourceName: sourceName,
                credentials: credentials
            )
        }

        var attemptedLabels: [String] = []
        for candidate in candidates {
            attemptedLabels.append(candidate.label)
            let attemptCredentials = KeePassUnlockCredentials(
                password: candidate.password,
                keyFile: candidate.keyMaterial,
                keyFileName: credentials.keyFileName,
                candidateLabel: candidate.label
            )
            do {
                return try baseReader.readSnapshot(
                    database: database,
                    sourceName: sourceName,
                    credentials: attemptCredentials
                )
            } catch let error as KeePassOperationError where error.code == .invalidCredential {
                continue
            }
        }

        throw KeePassOperationError(
            code: .invalidCredential,
            message: KeePassCredentialSupport.invalidCredentialMessage(attemptedLabels: attemptedLabels)
        )
    }
}

public struct DefaultKeePassDatabaseReader: KeePassDatabaseReader {
    private let xmlReader = KeePassXMLReadOnlySnapshotReader()
    private let payloadDecryptor: any KeePassKdbxPayloadDecryptor

    public init(payloadDecryptor: any KeePassKdbxPayloadDecryptor = DefaultKeePassKdbxPayloadDecryptor()) {
        self.payloadDecryptor = payloadDecryptor
    }

    public func readSnapshot(
        database: Data,
        sourceName: String?,
        credentials: KeePassUnlockCredentials
    ) throws -> KeePassReadOnlySnapshot {
        if KeePassXMLReadOnlySnapshotReader.canRead(database) {
            return try xmlReader.readSnapshot(
                database: database,
                sourceName: sourceName,
                credentials: credentials
            )
        }
        if let inflated = KeePassGzipPayloadInflator.inflate(database),
           KeePassXMLReadOnlySnapshotReader.canRead(inflated) {
            return try xmlReader.readSnapshot(
                database: inflated,
                sourceName: sourceName,
                credentials: credentials
            )
        }
        if KeePassFormatInspector.detect(database, sourceName: sourceName) == .kdbx {
            let candidate = KeePassCredentialCandidate(
                label: credentials.candidateLabel ?? credentials.summary.displayName,
                password: credentials.password,
                keyMaterial: credentials.keyFile
            )
            let context = try KeePassKdbxDecryptInputContext.build(
                database: database,
                sourceName: sourceName,
                credentialCandidate: candidate
            )
            let decryptedPayload = try payloadDecryptor.decryptPayload(context)
            if let snapshot = try readDecryptedPayloadSnapshot(
                decryptedPayload,
                sourceName: sourceName,
                credentials: credentials,
                headerSummary: context.envelope.headerSummary,
                cryptoInputs: context.cryptoInputs
            ) {
                return snapshot
            }
            if context.envelope.headerSummary.formatVersion == .kdbx4,
               let innerPayload = KeePassKdbx4InnerHeaderParser.parse(decryptedPayload),
               let snapshot = try readDecryptedPayloadSnapshot(
                innerPayload.payload,
                sourceName: sourceName,
                credentials: credentials,
                headerSummary: context.envelope.headerSummary,
                cryptoInputs: innerPayload.cryptoInputs(base: context.cryptoInputs),
                externalBinaries: innerPayload.binaries
               ) {
                return snapshot
            }
        }
        throw KeePassOperationError(
            code: .formatUnsupported,
            message: "KDBX 解码器尚未接入"
        )
    }

    private func readDecryptedPayloadSnapshot(
        _ payload: Data,
        sourceName: String?,
        credentials: KeePassUnlockCredentials,
        headerSummary: KeePassHeaderSummary,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs,
        externalBinaries: [String: Data] = [:]
    ) throws -> KeePassReadOnlySnapshot? {
        if KeePassXMLReadOnlySnapshotReader.canRead(payload) {
            return try xmlReader.readSnapshot(
                database: payload,
                sourceName: sourceName,
                credentials: credentials,
                headerSummary: headerSummary,
                cryptoInputs: cryptoInputs,
                externalBinaries: externalBinaries
            )
        }
        if let inflated = KeePassGzipPayloadInflator.inflate(payload),
           KeePassXMLReadOnlySnapshotReader.canRead(inflated) {
            return try xmlReader.readSnapshot(
                database: inflated,
                sourceName: sourceName,
                credentials: credentials,
                headerSummary: headerSummary,
                cryptoInputs: cryptoInputs,
                externalBinaries: externalBinaries
            )
        }
        return nil
    }
}

private struct KeePassKdbx4InnerHeaderPayload {
    let innerRandomStreamID: UInt32?
    let innerRandomStreamKey: Data?
    let binaries: [String: Data]
    let payload: Data

    func cryptoInputs(base: KeePassKdbxPayloadCryptoInputs) -> KeePassKdbxPayloadCryptoInputs {
        base.mergedWithKdbx4InnerHeader(
            innerRandomStreamKey: innerRandomStreamKey,
            innerRandomStreamID: innerRandomStreamID
        )
    }
}

private enum KeePassKdbx4InnerHeaderParser {
    private static let endField: UInt8 = 0
    private static let innerRandomStreamIDField: UInt8 = 1
    private static let innerRandomStreamKeyField: UInt8 = 2
    private static let binaryField: UInt8 = 3

    static func parse(_ decryptedPayload: Data) -> KeePassKdbx4InnerHeaderPayload? {
        var offset = 0
        var innerRandomStreamID: UInt32?
        var innerRandomStreamKey: Data?
        var binaries: [String: Data] = [:]
        var nextBinaryID = 0
        while offset < decryptedPayload.count {
            let fieldID = decryptedPayload[offset]
            offset += 1
            guard let length = readLittleEndianUInt32(from: decryptedPayload, at: offset) else {
                return nil
            }
            offset += 4
            guard Int(length) <= decryptedPayload.count - offset else {
                return nil
            }
            let value = Data(decryptedPayload[offset..<offset + Int(length)])
            offset += Int(length)

            switch fieldID {
            case endField:
                guard length == 0, offset < decryptedPayload.count else {
                    return nil
                }
                return KeePassKdbx4InnerHeaderPayload(
                    innerRandomStreamID: innerRandomStreamID,
                    innerRandomStreamKey: innerRandomStreamKey,
                    binaries: binaries,
                    payload: Data(decryptedPayload[offset..<decryptedPayload.count])
                )
            case innerRandomStreamIDField:
                guard value.count == MemoryLayout<UInt32>.size else {
                    return nil
                }
                innerRandomStreamID = readLittleEndianUInt32(from: value, at: 0)
            case innerRandomStreamKeyField:
                innerRandomStreamKey = value
            case binaryField:
                let content = value.isEmpty ? Data() : Data(value.dropFirst())
                binaries[String(nextBinaryID)] = content
                nextBinaryID += 1
            default:
                continue
            }
        }
        return nil
    }

    private static func readLittleEndianUInt32(from data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else {
            return nil
        }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

private enum KeePassGzipPayloadInflator {
    private static let gzipMagic = Data([0x1F, 0x8B])
    private static let chunkSize = 64 * 1024

    static func inflate(_ data: Data) -> Data? {
        guard data.starts(with: gzipMagic) else {
            return nil
        }

        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            16 + MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            return nil
        }
        defer {
            inflateEnd(&stream)
        }

        var output = Data()
        let status = data.withUnsafeBytes { inputBuffer -> Int32 in
            guard let inputBase = inputBuffer.baseAddress else {
                return Z_DATA_ERROR
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(data.count)

            var status: Int32 = Z_OK
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            while status == Z_OK {
                let produced = buffer.withUnsafeMutableBytes { outputBuffer -> Int32 in
                    guard let outputBase = outputBuffer.baseAddress else {
                        return Z_BUF_ERROR
                    }
                    stream.next_out = outputBase.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(chunkSize)
                    let stepStatus = zlib.inflate(&stream, Z_NO_FLUSH)
                    let written = chunkSize - Int(stream.avail_out)
                    if written > 0 {
                        output.append(outputBase.assumingMemoryBound(to: UInt8.self), count: written)
                    }
                    return stepStatus
                }
                status = produced
            }
            return status
        }

        return status == Z_STREAM_END ? output : nil
    }
}

public struct KeePassGzipPayloadCompressor: Sendable {
    private static let chunkSize = 64 * 1024

    public init() {}

    public func compress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            16 + MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KeePass GZip payload 压缩器初始化失败；请重试。"
            )
        }
        defer {
            deflateEnd(&stream)
        }

        var output = Data()
        let status = data.withUnsafeBytes { inputBuffer -> Int32 in
            guard data.isEmpty || inputBuffer.baseAddress != nil else {
                return Z_DATA_ERROR
            }
            if let inputBase = inputBuffer.baseAddress {
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase.assumingMemoryBound(to: Bytef.self))
                stream.avail_in = uInt(data.count)
            }

            var status: Int32 = Z_OK
            var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
            repeat {
                let produced = buffer.withUnsafeMutableBytes { outputBuffer -> Int32 in
                    guard let outputBase = outputBuffer.baseAddress else {
                        return Z_BUF_ERROR
                    }
                    stream.next_out = outputBase.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(Self.chunkSize)
                    let stepStatus = zlib.deflate(&stream, Z_FINISH)
                    let written = Self.chunkSize - Int(stream.avail_out)
                    if written > 0 {
                        output.append(outputBase.assumingMemoryBound(to: UInt8.self), count: written)
                    }
                    return stepStatus
                }
                status = produced
            } while status == Z_OK
            return status
        }

        guard status == Z_STREAM_END else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KeePass GZip payload 压缩失败；请重试。"
            )
        }
        return output
    }
}

public struct KeePassKdbx4WritebackRequest: Sendable, Equatable {
    public let snapshot: KeePassReadOnlySnapshot
    public let credentials: KeePassUnlockCredentials
    public let cipher: KeePassKdbxCipherAlgorithm
    public let compression: KeePassKdbxCompressionAlgorithm
    public let cryptoInputs: KeePassKdbxPayloadCryptoInputs
    public let kdfParameters: KeePassKdbxKdfParameters
    public let existingHeaderBytes: Data?

    public init(
        snapshot: KeePassReadOnlySnapshot,
        credentials: KeePassUnlockCredentials,
        cipher: KeePassKdbxCipherAlgorithm,
        compression: KeePassKdbxCompressionAlgorithm,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs,
        kdfParameters: KeePassKdbxKdfParameters,
        existingHeaderBytes: Data? = nil
    ) {
        self.snapshot = snapshot
        self.credentials = credentials
        self.cipher = cipher
        self.compression = compression
        self.cryptoInputs = cryptoInputs
        self.kdfParameters = kdfParameters
        self.existingHeaderBytes = existingHeaderBytes
    }
}

public struct KeePassKdbx4WritebackResult: Sendable, Equatable {
    public let database: Data
    public let headerBytes: Data
    public let payloadSection: Data
    public let xmlPayloadByteCount: Int
    public let groupCount: Int
    public let entryCount: Int
    public let attachmentCount: Int

    public init(
        database: Data,
        headerBytes: Data,
        payloadSection: Data,
        xmlPayloadByteCount: Int,
        groupCount: Int,
        entryCount: Int,
        attachmentCount: Int
    ) {
        self.database = database
        self.headerBytes = headerBytes
        self.payloadSection = payloadSection
        self.xmlPayloadByteCount = xmlPayloadByteCount
        self.groupCount = groupCount
        self.entryCount = entryCount
        self.attachmentCount = attachmentCount
    }

    public var displaySummary: String {
        "KDBX4 writeback，\(groupCount) 个分组，\(entryCount) 个条目，\(attachmentCount) 个附件，XML \(xmlPayloadByteCount) bytes，database \(database.count) bytes"
    }
}

public struct KeePassKdbx3WritebackRequest: Sendable, Equatable {
    public let snapshot: KeePassReadOnlySnapshot
    public let credentials: KeePassUnlockCredentials
    public let cipher: KeePassKdbxCipherAlgorithm
    public let compression: KeePassKdbxCompressionAlgorithm
    public let cryptoInputs: KeePassKdbxPayloadCryptoInputs
    public let kdfParameters: KeePassKdbxKdfParameters
    public let existingHeaderBytes: Data?

    public init(
        snapshot: KeePassReadOnlySnapshot,
        credentials: KeePassUnlockCredentials,
        cipher: KeePassKdbxCipherAlgorithm,
        compression: KeePassKdbxCompressionAlgorithm,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs,
        kdfParameters: KeePassKdbxKdfParameters,
        existingHeaderBytes: Data? = nil
    ) {
        self.snapshot = snapshot
        self.credentials = credentials
        self.cipher = cipher
        self.compression = compression
        self.cryptoInputs = cryptoInputs
        self.kdfParameters = kdfParameters
        self.existingHeaderBytes = existingHeaderBytes
    }
}

public struct KeePassKdbx3WritebackResult: Sendable, Equatable {
    public let database: Data
    public let headerBytes: Data
    public let encryptedPayload: Data
    public let xmlPayloadByteCount: Int
    public let groupCount: Int
    public let entryCount: Int
    public let attachmentCount: Int

    public init(
        database: Data,
        headerBytes: Data,
        encryptedPayload: Data,
        xmlPayloadByteCount: Int,
        groupCount: Int,
        entryCount: Int,
        attachmentCount: Int
    ) {
        self.database = database
        self.headerBytes = headerBytes
        self.encryptedPayload = encryptedPayload
        self.xmlPayloadByteCount = xmlPayloadByteCount
        self.groupCount = groupCount
        self.entryCount = entryCount
        self.attachmentCount = attachmentCount
    }

    public var displaySummary: String {
        "KDBX3 writeback，\(groupCount) 个分组，\(entryCount) 个条目，\(attachmentCount) 个附件，XML \(xmlPayloadByteCount) bytes，database \(database.count) bytes"
    }
}

public protocol KeePassKdbx3WritebackCoordinator: Sendable {
    func writeDatabase(_ request: KeePassKdbx3WritebackRequest) throws -> KeePassKdbx3WritebackResult
}

public struct DefaultKeePassKdbx3WritebackCoordinator: KeePassKdbx3WritebackCoordinator {
    private let xmlPayloadWriter: KeePassXMLPayloadWriter?
    private let gzipPayloadCompressor: KeePassGzipPayloadCompressor
    private let headerWriter: any KeePassKdbx3HeaderWriter
    private let keyDeriver: any KeePassKdbxKeyDeriver
    private let masterKeyComposer: any KeePassKdbxMasterKeyComposer
    private let blockStreamEncoder: any KeePassKdbxBlockStreamEncoder
    private let payloadCipher: any KeePassKdbxPayloadCipher

    public init(
        xmlPayloadWriter: KeePassXMLPayloadWriter? = nil,
        gzipPayloadCompressor: KeePassGzipPayloadCompressor = KeePassGzipPayloadCompressor(),
        headerWriter: any KeePassKdbx3HeaderWriter = DefaultKeePassKdbx3HeaderWriter(),
        keyDeriver: any KeePassKdbxKeyDeriver = DefaultKeePassKdbxKeyDeriver(),
        masterKeyComposer: any KeePassKdbxMasterKeyComposer = DefaultKeePassKdbxMasterKeyComposer(),
        blockStreamEncoder: any KeePassKdbxBlockStreamEncoder = DefaultKeePassKdbxBlockStreamEncoder(),
        payloadCipher: any KeePassKdbxPayloadCipher = DefaultKeePassKdbxPayloadCipher()
    ) {
        self.xmlPayloadWriter = xmlPayloadWriter
        self.gzipPayloadCompressor = gzipPayloadCompressor
        self.headerWriter = headerWriter
        self.keyDeriver = keyDeriver
        self.masterKeyComposer = masterKeyComposer
        self.blockStreamEncoder = blockStreamEncoder
        self.payloadCipher = payloadCipher
    }

    public func writeDatabase(_ request: KeePassKdbx3WritebackRequest) throws -> KeePassKdbx3WritebackResult {
        let headerBytes: Data
        if let existingHeaderBytes = request.existingHeaderBytes {
            try validateExistingHeaderBytes(existingHeaderBytes, expectedVersion: .kdbx3)
            headerBytes = existingHeaderBytes
        } else {
            headerBytes = try headerWriter.writeHeader(
                cipher: request.cipher,
                compression: request.compression,
                cryptoInputs: request.cryptoInputs,
                kdfParameters: request.kdfParameters
            )
        }
        let xmlPayloadWriter = xmlPayloadWriter ?? KeePassXMLPayloadWriter(
            protectedValueMode: .encryptProtectedValues(request.cryptoInputs),
            binaryMode: .inlineMetaBinaries
        )
        let xmlPayload = try xmlPayloadWriter.write(request.snapshot)
        let payloadPlaintext = try compressedPayloadIfNeeded(
            xmlPayload.xmlPayload,
            compression: request.compression
        )
        let blockStream = try blockStreamEncoder.encodeBlockStream(
            payloadPlaintext,
            context: KeePassKdbxBlockStreamContext(
                formatVersion: .kdbx3,
                streamStartBytes: request.cryptoInputs.streamStartBytes
            )
        )
        let credentialCandidate = try writebackCredentialCandidate(from: request.credentials)
        let context = try KeePassKdbxDecryptInputContext.build(
            database: headerBytes + Data("writeback-placeholder".utf8),
            sourceName: request.snapshot.sourceName,
            credentialCandidate: credentialCandidate
        )
        let derivedKey = try keyDeriver.deriveKey(from: context)
        let masterKey = try masterKeyComposer.composeMasterKey(
            from: derivedKey,
            cryptoInputs: request.cryptoInputs
        )
        let encryptedPayload = try payloadCipher.encryptPayload(
            blockStream,
            cipher: request.cipher,
            masterKey: masterKey,
            cryptoInputs: request.cryptoInputs
        )
        var database = Data()
        database.reserveCapacity(headerBytes.count + encryptedPayload.count)
        database.append(headerBytes)
        database.append(encryptedPayload)
        return KeePassKdbx3WritebackResult(
            database: database,
            headerBytes: headerBytes,
            encryptedPayload: encryptedPayload,
            xmlPayloadByteCount: xmlPayload.xmlPayload.count,
            groupCount: xmlPayload.groupCount,
            entryCount: xmlPayload.entryCount,
            attachmentCount: xmlPayload.attachmentCount
        )
    }

    private func compressedPayloadIfNeeded(
        _ xmlPayload: Data,
        compression: KeePassKdbxCompressionAlgorithm
    ) throws -> Data {
        switch compression {
        case .none:
            return xmlPayload
        case .gzip:
            return try gzipPayloadCompressor.compress(xmlPayload)
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KDBX3 compression writeback 尚未接入"
            )
        }
    }

    private func writebackCredentialCandidate(from credentials: KeePassUnlockCredentials) throws -> KeePassCredentialCandidate {
        if let candidateLabel = credentials.candidateLabel,
           let candidate = credentials.credentialCandidates.first(where: { $0.label == candidateLabel }) {
            return candidate
        }
        guard let candidate = credentials.credentialCandidates.first else {
            throw KeePassOperationError(
                code: .invalidCredential,
                message: "KDBX3 写回需要数据库密码或密钥文件"
            )
        }
        return candidate
    }

    private func validateExistingHeaderBytes(
        _ headerBytes: Data,
        expectedVersion: KeePassKdbxFormatVersion
    ) throws {
        let envelope = try KeePassKdbxPayloadEnvelope.parse(headerBytes)
        guard envelope.headerSummary.formatVersion == expectedVersion,
              envelope.headerBytes == headerBytes,
              envelope.encryptedPayload.isEmpty else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX 原始 header 无法复用；请确认文件未损坏。"
            )
        }
    }
}

public protocol KeePassKdbx4WritebackCoordinator: Sendable {
    func writeDatabase(_ request: KeePassKdbx4WritebackRequest) throws -> KeePassKdbx4WritebackResult
}

public struct DefaultKeePassKdbx4WritebackCoordinator: KeePassKdbx4WritebackCoordinator {
    private let xmlPayloadWriter: KeePassXMLPayloadWriter?
    private let gzipPayloadCompressor: KeePassGzipPayloadCompressor
    private let headerWriter: any KeePassKdbx4HeaderWriter
    private let keyDeriver: any KeePassKdbxKeyDeriver
    private let masterKeyComposer: any KeePassKdbxMasterKeyComposer
    private let payloadCipher: any KeePassKdbxPayloadCipher
    private let payloadSectionWriter: any KeePassKdbx4PayloadSectionWriter
    private let fileAssembler: any KeePassKdbxFileAssembler

    public init(
        xmlPayloadWriter: KeePassXMLPayloadWriter? = nil,
        gzipPayloadCompressor: KeePassGzipPayloadCompressor = KeePassGzipPayloadCompressor(),
        headerWriter: any KeePassKdbx4HeaderWriter = DefaultKeePassKdbx4HeaderWriter(),
        keyDeriver: any KeePassKdbxKeyDeriver = DefaultKeePassKdbxKeyDeriver(),
        masterKeyComposer: any KeePassKdbxMasterKeyComposer = DefaultKeePassKdbxMasterKeyComposer(),
        payloadCipher: any KeePassKdbxPayloadCipher = DefaultKeePassKdbxPayloadCipher(),
        payloadSectionWriter: any KeePassKdbx4PayloadSectionWriter = DefaultKeePassKdbx4PayloadSectionWriter(),
        fileAssembler: any KeePassKdbxFileAssembler = DefaultKeePassKdbxFileAssembler()
    ) {
        self.xmlPayloadWriter = xmlPayloadWriter
        self.gzipPayloadCompressor = gzipPayloadCompressor
        self.headerWriter = headerWriter
        self.keyDeriver = keyDeriver
        self.masterKeyComposer = masterKeyComposer
        self.payloadCipher = payloadCipher
        self.payloadSectionWriter = payloadSectionWriter
        self.fileAssembler = fileAssembler
    }

    public func writeDatabase(_ request: KeePassKdbx4WritebackRequest) throws -> KeePassKdbx4WritebackResult {
        let headerBytes: Data
        if let existingHeaderBytes = request.existingHeaderBytes {
            try validateExistingHeaderBytes(existingHeaderBytes, expectedVersion: .kdbx4)
            headerBytes = existingHeaderBytes
        } else {
            headerBytes = try headerWriter.writeHeader(
                cipher: request.cipher,
                compression: request.compression,
                cryptoInputs: request.cryptoInputs,
                kdfParameters: request.kdfParameters
            )
        }
        let xmlPayloadWriter = xmlPayloadWriter ?? KeePassXMLPayloadWriter(
            protectedValueMode: .encryptProtectedValues(request.cryptoInputs),
            binaryMode: .externalReferences
        )
        let xmlPayload = try xmlPayloadWriter.write(request.snapshot)
        let payloadPlaintext = try compressedPayloadIfNeeded(
            xmlPayload.xmlPayload,
            compression: request.compression
        )
        let kdbx4Plaintext = try kdbx4Plaintext(
            payloadPlaintext,
            binaryContents: xmlPayload.binaryContents,
            cryptoInputs: request.cryptoInputs
        )
        let credentialCandidate = try writebackCredentialCandidate(from: request.credentials)
        let context = try KeePassKdbxDecryptInputContext.build(
            database: headerBytes + Data("writeback-placeholder".utf8),
            sourceName: request.snapshot.sourceName,
            credentialCandidate: credentialCandidate
        )
        let derivedKey = try keyDeriver.deriveKey(from: context)
        let masterKey = try masterKeyComposer.composeMasterKey(
            from: derivedKey,
            cryptoInputs: request.cryptoInputs
        )
        let encryptedPayload = try payloadCipher.encryptPayload(
            kdbx4Plaintext,
            cipher: request.cipher,
            masterKey: masterKey,
            cryptoInputs: request.cryptoInputs
        )
        let masterSeed = try requireMasterSeed(request.cryptoInputs.masterSeed)
        let payloadSection = try payloadSectionWriter.writePayloadSection(
            encryptedPayloadBlocks: [encryptedPayload],
            headerBytes: headerBytes,
            masterSeed: masterSeed,
            derivedKey: derivedKey
        )
        let database = try fileAssembler.assemble(headerBytes: headerBytes, payloadSection: payloadSection)
        return KeePassKdbx4WritebackResult(
            database: database,
            headerBytes: headerBytes,
            payloadSection: payloadSection,
            xmlPayloadByteCount: xmlPayload.xmlPayload.count,
            groupCount: xmlPayload.groupCount,
            entryCount: xmlPayload.entryCount,
            attachmentCount: xmlPayload.attachmentCount
        )
    }

    private func kdbx4Plaintext(
        _ payloadPlaintext: Data,
        binaryContents: [Data],
        cryptoInputs: KeePassKdbxPayloadCryptoInputs
    ) throws -> Data {
        var innerHeader = Data()
        if let innerRandomStreamID = cryptoInputs.innerRandomStreamID {
            innerHeader.append(innerHeaderField(id: 1, value: littleEndianUInt32(innerRandomStreamID)))
        }
        if let innerRandomStreamKey = cryptoInputs.innerRandomStreamKey {
            innerHeader.append(innerHeaderField(id: 2, value: innerRandomStreamKey))
        }
        for content in binaryContents {
            innerHeader.append(innerHeaderField(id: 3, value: Data([0x00]) + content))
        }
        innerHeader.append(innerHeaderField(id: 0, value: Data()))
        return innerHeader + payloadPlaintext
    }

    private func innerHeaderField(id: UInt8, value: Data) -> Data {
        Data([id]) + littleEndianUInt32(UInt32(value.count)) + value
    }

    private func littleEndianUInt32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    private func compressedPayloadIfNeeded(
        _ xmlPayload: Data,
        compression: KeePassKdbxCompressionAlgorithm
    ) throws -> Data {
        switch compression {
        case .none:
            return xmlPayload
        case .gzip:
            return try gzipPayloadCompressor.compress(xmlPayload)
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KDBX compression writeback 尚未接入"
            )
        }
    }

    private func validateExistingHeaderBytes(
        _ headerBytes: Data,
        expectedVersion: KeePassKdbxFormatVersion
    ) throws {
        let envelope = try KeePassKdbxPayloadEnvelope.parse(headerBytes)
        guard envelope.headerSummary.formatVersion == expectedVersion,
              envelope.headerBytes == headerBytes,
              envelope.encryptedPayload.isEmpty else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX 原始 header 无法复用；请确认文件未损坏。"
            )
        }
    }

    private func writebackCredentialCandidate(from credentials: KeePassUnlockCredentials) throws -> KeePassCredentialCandidate {
        if let candidateLabel = credentials.candidateLabel,
           let candidate = credentials.credentialCandidates.first(where: { $0.label == candidateLabel }) {
            return candidate
        }
        guard let candidate = credentials.credentialCandidates.first else {
            throw KeePassOperationError(
                code: .invalidCredential,
                message: "KDBX 写回需要数据库密码或密钥文件"
            )
        }
        return candidate
    }

    private func requireMasterSeed(_ masterSeed: Data?) throws -> Data {
        guard let masterSeed, masterSeed.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX4 writeback master seed 长度无效；请确认写回参数完整。"
            )
        }
        return masterSeed
    }
}

public struct UnsupportedKeePassDatabaseReader: KeePassDatabaseReader {
    public init() {}

    public func readSnapshot(
        database: Data,
        sourceName: String?,
        credentials: KeePassUnlockCredentials
    ) throws -> KeePassReadOnlySnapshot {
        throw KeePassOperationError(
            code: .formatUnsupported,
            message: "KDBX 解码器尚未接入"
        )
    }
}

public struct KeePassXMLReadOnlySnapshotReader: KeePassDatabaseReader {
    public init() {}

    public static func canRead(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(512), encoding: .utf8) else {
            return false
        }
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<KeePassFile")
    }

    public func readSnapshot(
        database: Data,
        sourceName: String?,
        credentials: KeePassUnlockCredentials
    ) throws -> KeePassReadOnlySnapshot {
        try readSnapshot(
            database: database,
            sourceName: sourceName,
            credentials: credentials,
            headerSummary: nil
        )
    }

    func readSnapshot(
        database: Data,
        sourceName: String?,
        credentials: KeePassUnlockCredentials,
        headerSummary: KeePassHeaderSummary?,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs = .empty,
        externalBinaries: [String: Data] = [:]
    ) throws -> KeePassReadOnlySnapshot {
        let parser = KeePassXMLSnapshotParser(
            protectedValueDecoder: try KeePassProtectedValueStreamDecoder.make(from: cryptoInputs),
            externalBinaries: externalBinaries
        )
        do {
            let parsed = try parser.parse(database)
            return KeePassXMLSnapshotBuilder.build(
                parsed,
                sourceName: sourceName,
                headerSummary: headerSummary
            )
        } catch {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KeePass XML 无法解析；请确认已提供解密后的 KDBX XML。"
            )
        }
    }
}

private final class KeePassProtectedValueStreamDecoder {
    fileprivate static let salsa20IV = Data([0xE8, 0x30, 0x09, 0x4B, 0x97, 0x20, 0x5D, 0x2A])

    private let keyStream: KeePassInnerRandomKeyStream

    private init(keyStream: KeePassInnerRandomKeyStream) {
        self.keyStream = keyStream
    }

    static func make(from cryptoInputs: KeePassKdbxPayloadCryptoInputs) throws -> KeePassProtectedValueStreamDecoder? {
        guard let innerRandomStreamKey = cryptoInputs.innerRandomStreamKey else {
            return nil
        }
        switch cryptoInputs.innerRandomStreamAlgorithm {
        case .none, .arc4Variant:
            return nil
        case .salsa20:
            guard innerRandomStreamKey.count == SHA256.byteCount else {
                throw KeePassOperationError(
                    code: .formatUnsupported,
                    message: "KeePass inner stream key 长度无效；请确认文件未损坏。"
                )
            }
            let key = Data(SHA256.hash(data: innerRandomStreamKey))
            return KeePassProtectedValueStreamDecoder(
                keyStream: KeePassSalsa20KeyStream(key: key, iv: salsa20IV)
            )
        case .chacha20:
            guard innerRandomStreamKey.count == SHA512.byteCount else {
                throw KeePassOperationError(
                    code: .formatUnsupported,
                    message: "KeePass inner stream key 长度无效；请确认文件未损坏。"
                )
            }
            let hash = Data(SHA512.hash(data: innerRandomStreamKey))
            let key = Data(hash.prefix(32))
            let nonce = Data(hash.dropFirst(32).prefix(12))
            return KeePassProtectedValueStreamDecoder(
                keyStream: KeePassChaCha20KeyStream(key: key, nonce: nonce)
            )
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KeePass protected value stream 尚未接入"
            )
        }
    }

    func decode(_ protectedBase64: String) throws -> String {
        let normalized = protectedBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encrypted = Data(base64Encoded: normalized) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KeePass protected value 无法解析；请确认文件未损坏。"
            )
        }
        let decrypted = keyStream.xor(encrypted)
        guard let decoded = String(data: decrypted, encoding: .utf8) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KeePass protected value 不是有效 UTF-8；请确认文件未损坏。"
            )
        }
        return decoded
    }
}

private final class KeePassProtectedValueStreamEncoder {
    private let keyStream: KeePassInnerRandomKeyStream

    private init(keyStream: KeePassInnerRandomKeyStream) {
        self.keyStream = keyStream
    }

    static func make(from cryptoInputs: KeePassKdbxPayloadCryptoInputs) throws -> KeePassProtectedValueStreamEncoder? {
        guard let innerRandomStreamKey = cryptoInputs.innerRandomStreamKey else {
            return nil
        }
        switch cryptoInputs.innerRandomStreamAlgorithm {
        case .none, .arc4Variant:
            return nil
        case .salsa20:
            guard innerRandomStreamKey.count == SHA256.byteCount else {
                throw KeePassOperationError(
                    code: .formatUnsupported,
                    message: "KeePass inner stream key 长度无效；请确认写回参数完整。"
                )
            }
            let key = Data(SHA256.hash(data: innerRandomStreamKey))
            return KeePassProtectedValueStreamEncoder(
                keyStream: KeePassSalsa20KeyStream(key: key, iv: KeePassProtectedValueStreamDecoder.salsa20IV)
            )
        case .chacha20:
            guard innerRandomStreamKey.count == SHA512.byteCount else {
                throw KeePassOperationError(
                    code: .formatUnsupported,
                    message: "KeePass inner stream key 长度无效；请确认写回参数完整。"
                )
            }
            let hash = Data(SHA512.hash(data: innerRandomStreamKey))
            let key = Data(hash.prefix(32))
            let nonce = Data(hash.dropFirst(32).prefix(12))
            return KeePassProtectedValueStreamEncoder(
                keyStream: KeePassChaCha20KeyStream(key: key, nonce: nonce)
            )
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KeePass protected value stream 写回尚未接入"
            )
        }
    }

    func encode(_ value: String) -> String {
        keyStream.xor(Data(value.utf8)).base64EncodedString()
    }
}

private protocol KeePassInnerRandomKeyStream: AnyObject {
    func xor(_ data: Data) -> Data
}

private final class KeePassChaCha20KeyStream: KeePassInnerRandomKeyStream {
    private let key: [UInt8]
    private let nonce: [UInt8]
    private var counter: UInt32 = 0
    private var block = [UInt8]()
    private var blockOffset = 0

    init(key: Data, nonce: Data) {
        self.key = [UInt8](key)
        self.nonce = [UInt8](nonce)
    }

    func xor(_ data: Data) -> Data {
        var output = [UInt8]()
        output.reserveCapacity(data.count)
        for byte in data {
            output.append(byte ^ nextByte())
        }
        return Data(output)
    }

    private func nextByte() -> UInt8 {
        if blockOffset >= block.count {
            block = Self.block(key: key, nonce: nonce, counter: counter)
            counter &+= 1
            blockOffset = 0
        }
        defer { blockOffset += 1 }
        return block[blockOffset]
    }

    private static func block(key: [UInt8], nonce: [UInt8], counter: UInt32) -> [UInt8] {
        let constants = [UInt8]("expand 32-byte k".utf8)
        let initial: [UInt32] = [
            word(constants, 0), word(constants, 4), word(constants, 8), word(constants, 12),
            word(key, 0), word(key, 4), word(key, 8), word(key, 12),
            word(key, 16), word(key, 20), word(key, 24), word(key, 28),
            counter,
            word(nonce, 0), word(nonce, 4), word(nonce, 8)
        ]
        var state = initial
        for _ in 0..<10 {
            quarterRound(&state, 0, 4, 8, 12)
            quarterRound(&state, 1, 5, 9, 13)
            quarterRound(&state, 2, 6, 10, 14)
            quarterRound(&state, 3, 7, 11, 15)
            quarterRound(&state, 0, 5, 10, 15)
            quarterRound(&state, 1, 6, 11, 12)
            quarterRound(&state, 2, 7, 8, 13)
            quarterRound(&state, 3, 4, 9, 14)
        }
        var output = [UInt8]()
        output.reserveCapacity(64)
        for index in 0..<16 {
            output.append(contentsOf: littleEndianUInt32Bytes(state[index] &+ initial[index]))
        }
        return output
    }

    private static func quarterRound(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        state[a] = state[a] &+ state[b]
        state[d] ^= state[a]
        state[d] = rotateLeft(state[d], by: 16)

        state[c] = state[c] &+ state[d]
        state[b] ^= state[c]
        state[b] = rotateLeft(state[b], by: 12)

        state[a] = state[a] &+ state[b]
        state[d] ^= state[a]
        state[d] = rotateLeft(state[d], by: 8)

        state[c] = state[c] &+ state[d]
        state[b] ^= state[c]
        state[b] = rotateLeft(state[b], by: 7)
    }

    private static func rotateLeft(_ value: UInt32, by shift: UInt32) -> UInt32 {
        (value << shift) | (value >> (32 - shift))
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func littleEndianUInt32Bytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ]
    }
}

private final class KeePassSalsa20KeyStream: KeePassInnerRandomKeyStream {
    private let key: [UInt8]
    private let iv: [UInt8]
    private var blockIndex: UInt64 = 0
    private var block = [UInt8]()
    private var blockOffset = 0

    init(key: Data, iv: Data) {
        self.key = [UInt8](key)
        self.iv = [UInt8](iv)
    }

    func xor(_ data: Data) -> Data {
        var output = [UInt8]()
        output.reserveCapacity(data.count)
        for byte in data {
            output.append(byte ^ nextByte())
        }
        return Data(output)
    }

    private func nextByte() -> UInt8 {
        if blockOffset >= block.count {
            block = Self.block(key: key, iv: iv, counter: blockIndex)
            blockIndex += 1
            blockOffset = 0
        }
        defer { blockOffset += 1 }
        return block[blockOffset]
    }

    private static func block(key: [UInt8], iv: [UInt8], counter: UInt64) -> [UInt8] {
        let constants = [UInt8]("expand 32-byte k".utf8)
        var nonce = iv
        nonce.append(contentsOf: littleEndianUInt64Bytes(counter))
        let initial: [UInt32] = [
            word(constants, 0),
            word(key, 0), word(key, 4), word(key, 8), word(key, 12),
            word(constants, 4),
            word(nonce, 0), word(nonce, 4), word(nonce, 8), word(nonce, 12),
            word(constants, 8),
            word(key, 16), word(key, 20), word(key, 24), word(key, 28),
            word(constants, 12)
        ]
        var state = initial
        for _ in 0..<10 {
            quarterRound(&state, 4, 8, 12, 0)
            quarterRound(&state, 9, 13, 1, 5)
            quarterRound(&state, 14, 2, 6, 10)
            quarterRound(&state, 3, 7, 11, 15)
            quarterRound(&state, 1, 2, 3, 0)
            quarterRound(&state, 6, 7, 4, 5)
            quarterRound(&state, 11, 8, 9, 10)
            quarterRound(&state, 12, 13, 14, 15)
        }
        var output = [UInt8]()
        output.reserveCapacity(64)
        for index in 0..<16 {
            output.append(contentsOf: littleEndianUInt32Bytes(state[index] &+ initial[index]))
        }
        return output
    }

    private static func quarterRound(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        state[a] ^= rotateLeft(state[d] &+ state[c], by: 7)
        state[b] ^= rotateLeft(state[a] &+ state[d], by: 9)
        state[c] ^= rotateLeft(state[b] &+ state[a], by: 13)
        state[d] ^= rotateLeft(state[c] &+ state[b], by: 18)
    }

    private static func rotateLeft(_ value: UInt32, by shift: UInt32) -> UInt32 {
        (value << shift) | (value >> (32 - shift))
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func littleEndianUInt32Bytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ]
    }

    private static func littleEndianUInt64Bytes(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> UInt64($0 * 8)) & 0xFF) }
    }
}

private struct ParsedKeePassXML {
    var rootGroups: [ParsedKeePassGroup] = []
    var recycleBinUUID: String?
    var binaries: [String: Data] = [:]
}

private struct ParsedKeePassGroup {
    var uuid = ""
    var name = ""
    var groups: [ParsedKeePassGroup] = []
    var entries: [ParsedKeePassEntry] = []
}

private struct ParsedKeePassEntry {
    var uuid = ""
    var strings: [ParsedKeePassStringField] = []
    var binaries: [ParsedKeePassEntryBinary] = []
}

private struct ParsedKeePassStringField {
    var key = ""
    var value = ""
    var isProtected = false
}

private struct ParsedKeePassEntryBinary {
    var key = ""
    var reference = ""
}

private final class KeePassXMLSnapshotParser: NSObject, XMLParserDelegate {
    private var parsed = ParsedKeePassXML()
    private let protectedValueDecoder: KeePassProtectedValueStreamDecoder?
    private var groupStack: [ParsedKeePassGroup] = []
    private var currentEntry: ParsedKeePassEntry?
    private var currentString: ParsedKeePassStringField?
    private var currentEntryBinary: ParsedKeePassEntryBinary?
    private var currentMetaBinaryID: String?
    private var currentText = ""
    private var elementStack: [String] = []
    private var parseFailure: Error?

    init(
        protectedValueDecoder: KeePassProtectedValueStreamDecoder? = nil,
        externalBinaries: [String: Data] = [:]
    ) {
        self.protectedValueDecoder = protectedValueDecoder
        parsed.binaries = externalBinaries
    }

    func parse(_ data: Data) throws -> ParsedKeePassXML {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), parseFailure == nil else {
            throw parseFailure ?? parser.parserError ?? KeePassOperationError(
                code: .formatUnsupported,
                message: "KeePass XML 无法解析"
            )
        }
        return parsed
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        elementStack.append(elementName)
        currentText = ""
        switch elementName {
        case "Group":
            groupStack.append(ParsedKeePassGroup())
        case "Entry":
            currentEntry = ParsedKeePassEntry()
        case "String":
            if currentEntry != nil {
                currentString = ParsedKeePassStringField()
            }
        case "Binary":
            if currentEntry != nil {
                currentEntryBinary = ParsedKeePassEntryBinary()
            } else if isInsideMetaBinaries {
                currentMetaBinaryID = attributeDict["ID"]
            }
        case "Value":
            if currentString != nil {
                currentString?.isProtected = attributeDict["Protected"].map(Self.boolValue) ?? false
            }
            if currentEntryBinary != nil {
                currentEntryBinary?.reference = attributeDict["Ref"] ?? ""
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer {
            if elementStack.last == elementName {
                elementStack.removeLast()
            }
            currentText = ""
        }

        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "UUID":
            if currentEntry != nil {
                currentEntry?.uuid = text
            } else if !groupStack.isEmpty {
                groupStack[groupStack.count - 1].uuid = text
            }
        case "Name":
            if currentEntry == nil, !groupStack.isEmpty {
                groupStack[groupStack.count - 1].name = text
            }
        case "RecycleBinUUID":
            parsed.recycleBinUUID = text.isEmpty ? nil : text
        case "Key":
            if currentString != nil {
                currentString?.key = text
            } else if currentEntryBinary != nil {
                currentEntryBinary?.key = text
            }
        case "Value":
            if currentString != nil {
                if currentString?.isProtected == true, let protectedValueDecoder {
                    do {
                        currentString?.value = try protectedValueDecoder.decode(text)
                    } catch {
                        parseFailure = error
                        currentString?.value = ""
                    }
                } else {
                    currentString?.value = text
                }
            }
        case "String":
            if let field = currentString {
                currentEntry?.strings.append(field)
            }
            currentString = nil
        case "Binary":
            if let binary = currentEntryBinary {
                currentEntry?.binaries.append(binary)
                currentEntryBinary = nil
            } else if let id = currentMetaBinaryID {
                parsed.binaries[id] = Data(base64Encoded: text) ?? Data()
                currentMetaBinaryID = nil
            }
        case "Entry":
            if let entry = currentEntry, !groupStack.isEmpty {
                groupStack[groupStack.count - 1].entries.append(entry)
            }
            currentEntry = nil
        case "Group":
            guard let group = groupStack.popLast() else { return }
            if groupStack.isEmpty {
                parsed.rootGroups.append(group)
            } else {
                groupStack[groupStack.count - 1].groups.append(group)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        parseFailure = parseError
    }

    private var isInsideMetaBinaries: Bool {
        elementStack.contains("Meta") && elementStack.contains("Binaries")
    }

    private static func boolValue(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "true" || normalized == "1" || normalized == "yes"
    }
}

private enum KeePassXMLSnapshotBuilder {
    static func build(
        _ parsed: ParsedKeePassXML,
        sourceName: String?,
        headerSummary: KeePassHeaderSummary?
    ) -> KeePassReadOnlySnapshot {
        var groups: [KeePassReadOnlyGroup] = []
        var entries: [KeePassReadOnlyEntry] = []
        for root in parsed.rootGroups {
            append(
                group: root,
                parentComponents: [],
                isRootGroup: true,
                parentDeleted: false,
                parsed: parsed,
                groups: &groups,
                entries: &entries
            )
        }
        return KeePassReadOnlySnapshot(
            sourceName: sourceName,
            headerSummary: headerSummary,
            groups: groups,
            entries: entries
        )
    }

    private static func append(
        group: ParsedKeePassGroup,
        parentComponents: [String],
        isRootGroup: Bool,
        parentDeleted: Bool,
        parsed: ParsedKeePassXML,
        groups: inout [KeePassReadOnlyGroup],
        entries: inout [KeePassReadOnlyEntry]
    ) {
        let title = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = isRootGroup ? [] : parentComponents + [title.isEmpty ? "Untitled" : title]
        let path = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
        let isDeleted = parentDeleted || (!group.uuid.isEmpty && group.uuid == parsed.recycleBinUUID)
        groups.append(
            KeePassReadOnlyGroup(
                id: group.uuid.isEmpty ? path : group.uuid,
                title: title.isEmpty ? "Root" : title,
                path: path,
                depth: components.count
            )
        )

        for entry in group.entries {
            entries.append(readOnlyEntry(
                entry,
                groupPath: path,
                groupID: group.uuid.isEmpty ? nil : group.uuid,
                isDeleted: isDeleted,
                binaries: parsed.binaries
            ))
        }
        for child in group.groups {
            append(
                group: child,
                parentComponents: components,
                isRootGroup: false,
                parentDeleted: isDeleted,
                parsed: parsed,
                groups: &groups,
                entries: &entries
            )
        }
    }

    private static func readOnlyEntry(
        _ entry: ParsedKeePassEntry,
        groupPath: String,
        groupID: String?,
        isDeleted: Bool,
        binaries: [String: Data]
    ) -> KeePassReadOnlyEntry {
        let title = firstFieldValue(entry, keys: ["Title", "Name"])
        let username = firstFieldValue(entry, keys: ["UserName", "Username", "User", "Login"])
        let password = firstFieldValue(entry, keys: ["Password", "Pass", "pass", "pwd", "PWD", "密码", "口令"])
        let url = firstFieldValue(entry, keys: ["URL", "Url", "Website", "URI"])
        let notes = firstFieldValue(entry, keys: ["Notes", "Note", "Comment"])
        let decodedTotp = decodedTotp(from: entry, title: title, username: username, url: url)
        let customFields = entry.strings.enumerated().compactMap { index, field -> KeePassReadOnlyCustomField? in
            let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !isReservedPasswordField(key) else {
                return nil
            }
            return KeePassReadOnlyCustomField(
                title: key,
                value: value,
                isProtected: field.isProtected,
                sortOrder: index
            )
        }
        let attachments = entry.binaries.enumerated().map { index, binary in
            let content = binaries[binary.reference]
            return KeePassReadOnlyAttachment(
                id: binary.reference.isEmpty ? "\(entry.uuid)-attachment-\(index)" : binary.reference,
                fileName: binary.key.isEmpty ? "Attachment \(index + 1)" : binary.key,
                mediaType: mediaType(for: binary.key),
                originalSize: Int64(content?.count ?? 0),
                contentHash: content.map { "sha256:" + sha256Hex($0) } ?? "",
                decodedContent: content
            )
        }
        return KeePassReadOnlyEntry(
            id: entry.uuid.isEmpty ? UUID().uuidString : entry.uuid,
            title: title.isEmpty ? "Untitled" : title,
            username: username,
            url: url,
            groupPath: groupPath,
            groupID: groupID,
            notes: notes,
            customFields: customFields,
            hasPassword: !password.isEmpty,
            decodedPassword: password.isEmpty ? nil : password,
            hasTotp: decodedTotp != nil,
            decodedTotp: decodedTotp,
            attachmentCount: attachments.count,
            isDeleted: isDeleted,
            attachments: attachments
        )
    }

    private static func firstFieldValue(_ entry: ParsedKeePassEntry, keys: [String]) -> String {
        let wanted = Set(keys.map { $0.lowercased() })
        return entry.strings.first { wanted.contains($0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func decodedTotp(
        from entry: ParsedKeePassEntry,
        title: String,
        username: String,
        url: String
    ) -> KeePassReadOnlyTotpSecret? {
        let otp = firstFieldValue(entry, keys: ["otp"])
        let seed = firstFieldValue(entry, keys: ["TOTP Seed", "TOTPSeed"])
        let settings = firstFieldValue(entry, keys: ["TOTP Settings", "TOTPSettings"])
        if let parsed = parseOtpAuthURI(otp, title: title, username: username) {
            return parsed
        }
        let secret = normalizeTotpSecret(otp.contains("://") ? seed : (otp.isEmpty ? seed : otp))
        guard !secret.isEmpty else {
            return nil
        }
        let parsedSettings = parseTotpSettings(settings)
        return KeePassReadOnlyTotpSecret(
            secret: secret,
            issuer: title.isEmpty ? nil : title,
            accountName: username.isEmpty ? nil : username,
            period: parsedSettings.period,
            digits: parsedSettings.digits,
            algorithm: parsedSettings.algorithm
        )
    }

    private static func parseOtpAuthURI(
        _ value: String,
        title: String,
        username: String
    ) -> KeePassReadOnlyTotpSecret? {
        guard value.lowercased().hasPrefix("otpauth://"),
              let components = URLComponents(string: value) else {
            return nil
        }
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            params[item.name.lowercased()] = item.value ?? ""
        }
        let secret = normalizeTotpSecret(params["secret"] ?? "")
        guard !secret.isEmpty else {
            return nil
        }
        let label = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let decodedLabel = label.removingPercentEncoding ?? label
        let labelParts = decodedLabel.split(separator: ":", maxSplits: 1).map(String.init)
        let issuer = params["issuer"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (labelParts.count == 2 ? labelParts[0] : nil)
            ?? (title.isEmpty ? nil : title)
        let account = (labelParts.count == 2 ? labelParts[1] : decodedLabel)
        return KeePassReadOnlyTotpSecret(
            secret: secret,
            issuer: issuer,
            accountName: account.isEmpty ? (username.isEmpty ? nil : username) : account,
            period: UInt32(params["period"] ?? ""),
            digits: UInt32(params["digits"] ?? ""),
            algorithm: params["algorithm"]?.uppercased()
        )
    }

    private static func parseTotpSettings(_ value: String) -> (period: UInt32?, digits: UInt32?, algorithm: String?) {
        var period: UInt32?
        var digits: UInt32?
        var algorithm: String?
        for pair in value.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "period", "step":
                period = UInt32(parts[1])
            case "digits":
                digits = UInt32(parts[1])
            case "algorithm", "algo":
                algorithm = parts[1].uppercased()
            default:
                continue
            }
        }
        return (period, digits, algorithm)
    }

    private static func normalizeTotpSecret(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
    }

    private static func isReservedPasswordField(_ key: String) -> Bool {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized.hasPrefix("_etm_") {
            return true
        }
        let reserved = [
            "Title", "Name",
            "UserName", "Username", "User", "Login",
            "Password", "Pass", "pass", "pwd", "PWD", "密码", "口令",
            "URL", "Url", "Website", "URI",
            "Notes", "Note", "Comment",
            "otp", "TOTP Seed", "TOTP Settings",
            "MonicaLocalId", "MonicaSecureItemId", "MonicaItemType", "MonicaItemData",
            "MonicaImagePaths", "MonicaIsFavorite",
            "MonicaPasskeyCredentialId", "MonicaPasskeyData", "MonicaPasskeyMode",
            "MonicaSshAlgorithm", "MonicaSshKeySize", "MonicaSshPublicKey",
            "MonicaSshPrivateKey", "MonicaSshFingerprint", "MonicaSshComment",
            "MonicaSshFormat",
            "SSID", "MonicaWifiData", "MonicaLoginType",
            "KPEX_PASSKEY", "KPEX_USERNAME", "KPEX_PRIVATE_KEY", "KPEX_CREDENTIAL_ID",
            "KPEX_USER_HANDLE", "KPEX_RELYING_PARTY", "KPEX_FLAG_BE", "KPEX_FLAG_BS"
        ]
        return Set(reserved.map { $0.lowercased() }).contains(normalized.lowercased())
    }

    private static func mediaType(for fileName: String) -> String {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "txt", "md", "csv", "json", "xml":
            return "text/plain"
        case "pdf":
            return "application/pdf"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        default:
            return "application/octet-stream"
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct KeePassOperationError: Error, Sendable, Equatable, LocalizedError {
    public let code: KeePassErrorCode
    public let message: String

    public init(code: KeePassErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public enum KeePassFormatInspector {
    fileprivate enum KdbxVariantValue {
        case byteArray(Data)
        case uint32(UInt32)
        case uint64(UInt64)
    }

    private struct ParsedKdbxHeader {
        let summary: KeePassHeaderSummary
        let fields: [UInt8: Data]
        let headerEndOffset: Int
    }

    private struct ParsedKdbxHeaderFields {
        let fields: [UInt8: Data]
        let headerEndOffset: Int
    }

    private static let kdbxSignature = Data([0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5])
    private static let kdbxVersionOffset = 8
    private static let kdbxVersionByteCount = 4
    private static let kdbxHeaderStartOffset = kdbxVersionOffset + kdbxVersionByteCount
    private static let kdbxCipherIDHeaderField: UInt8 = 2
    private static let kdbxCompressionFlagsHeaderField: UInt8 = 3
    private static let kdbxMasterSeedHeaderField: UInt8 = 4
    private static let kdbxTransformSeedHeaderField: UInt8 = 5
    private static let kdbxTransformRoundsHeaderField: UInt8 = 6
    private static let kdbxEncryptionIVHeaderField: UInt8 = 7
    private static let kdbxInnerRandomStreamKeyHeaderField: UInt8 = 8
    private static let kdbxStreamStartBytesHeaderField: UInt8 = 9
    private static let kdbxInnerRandomStreamIDHeaderField: UInt8 = 10
    private static let kdbxKdfParametersHeaderField: UInt8 = 11
    private static let kdbxEndHeaderField: UInt8 = 0
    private static let kdbxAes256CipherUUID = Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF])
    private static let kdbxChaCha20CipherUUID = Data([0xD6, 0x03, 0x8A, 0x2B, 0x8B, 0x6F, 0x4C, 0xB5, 0xA5, 0x24, 0x33, 0x9A, 0x31, 0xDB, 0xB5, 0x9A])
    private static let kdbxTwofishCipherUUID = Data([0xAD, 0x68, 0xF2, 0x9F, 0x57, 0x6F, 0x4B, 0xB9, 0xA3, 0x6A, 0xD4, 0x7A, 0xF9, 0x65, 0x34, 0x6C])
    private static let kdbxAesKdfUUID = Data([0xC9, 0xD9, 0xF3, 0x9A, 0x62, 0x8A, 0x44, 0x60, 0xBF, 0x74, 0x0D, 0x08, 0xC1, 0x8A, 0x4F, 0xEA])
    private static let kdbxArgon2dKdfUUID = Data([0xEF, 0x63, 0x6D, 0xDF, 0x8C, 0x29, 0x44, 0x4B, 0x91, 0xF7, 0xA9, 0xA4, 0x03, 0xE3, 0x0A, 0x0C])
    private static let kdbxArgon2idKdfUUID = Data([0x9E, 0x29, 0x8B, 0x19, 0x56, 0xDB, 0x47, 0x73, 0xB2, 0x3D, 0xFC, 0x3E, 0xC6, 0xF0, 0xA1, 0xE6])
    private static let legacyKdbSignatures = [
        Data([0x03, 0xD9, 0xA2, 0x9A, 0x65, 0xFB, 0x4B, 0xB5]),
        Data([0x03, 0xD9, 0xA2, 0x9A, 0x66, 0xFB, 0x4B, 0xB5])
    ]
    public static let legacyKdbUnsupportedMessage =
        "检测到旧版 .kdb（KeePass 1.x）数据库，当前仅支持 .kdbx。请先在 KeePassDX/KeePassXC 中另存为 .kdbx 后再导入。"
    public static let missingCredentialsMessage = "请输入数据库密码或选择密钥文件"

    public static func detect(_ data: Data, sourceName: String? = nil) -> KeePassContainerFormat {
        if data.starts(with: kdbxSignature) {
            return .kdbx
        }
        if legacyKdbSignatures.contains(where: { data.starts(with: $0) }) {
            return .legacyKdb
        }
        if sourceName?.isLikelyLegacyKdbExtension == true {
            return .legacyKdb
        }
        return .unknown
    }

    public static func inspect(_ data: Data, sourceName: String? = nil) -> KeePassImportPreviewReport {
        let format = detect(data, sourceName: sourceName)
        switch format {
        case .kdbx:
            return KeePassImportPreviewReport(
                format: format,
                status: .requiresCredentials,
                sourceName: sourceName,
                headerSummary: parseKdbxHeaderSummary(data),
                issue: nil
            )
        case .legacyKdb:
            return KeePassImportPreviewReport(
                format: format,
                status: .unsupported,
                sourceName: sourceName,
                headerSummary: nil,
                issue: KeePassImportIssue(
                    code: .legacyKdbUnsupported,
                    message: legacyKdbUnsupportedMessage
                )
            )
        case .unknown:
            return KeePassImportPreviewReport(
                format: format,
                status: .unknown,
                sourceName: sourceName,
                headerSummary: nil,
                issue: KeePassImportIssue(
                    code: .formatUnsupported,
                    message: "数据库格式不支持或文件已损坏。"
                )
            )
        }
    }

    public static func ensureKdbxSupported(_ data: Data, sourceName: String? = nil) throws {
        let report = inspect(data, sourceName: sourceName)
        guard report.format == .kdbx else {
            let issue = report.issue ?? KeePassImportIssue(
                code: .formatUnsupported,
                message: "数据库格式不支持或文件已损坏。"
            )
            throw KeePassOperationError(code: issue.code, message: issue.message)
        }
    }

    public static func prepareUnlock(
        _ data: Data,
        sourceName: String? = nil,
        password: String,
        keyFile: Data?,
        keyFileName: String?
    ) -> KeePassUnlockPreflightReport {
        let report = inspect(data, sourceName: sourceName)
        let credentials = KeePassCredentialSummary(
            hasPassword: !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasKeyFile: keyFile?.isEmpty == false,
            keyFileName: keyFileName?.sanitizedKeePassFileName,
            keyFileCandidateCount: keyFile.map {
                KeePassCredentialSupport.buildCredentialCandidates(password: password, keyFile: $0).count
            } ?? 0
        )

        if let issue = report.issue {
            return KeePassUnlockPreflightReport(
                format: report.format,
                status: report.status,
                sourceName: report.sourceName,
                headerSummary: report.headerSummary,
                credentials: credentials,
                issue: issue
            )
        }

        guard credentials.hasPassword || credentials.hasKeyFile else {
            return KeePassUnlockPreflightReport(
                format: report.format,
                status: .requiresCredentials,
                sourceName: report.sourceName,
                headerSummary: report.headerSummary,
                credentials: credentials,
                issue: KeePassImportIssue(code: .invalidCredential, message: missingCredentialsMessage)
            )
        }

        return KeePassUnlockPreflightReport(
            format: report.format,
            status: .readyToUnlock,
            sourceName: report.sourceName,
            headerSummary: report.headerSummary,
            credentials: credentials,
            issue: nil
        )
    }

    public static func parseKdbxPayloadEnvelope(_ data: Data) throws -> KeePassKdbxPayloadEnvelope {
        guard let parsed = parseKdbxHeader(data) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX header 无法解析；请确认文件未损坏。"
            )
        }
        let payloadStart = parsed.headerEndOffset
        guard payloadStart <= data.count else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX payload 无法解析；请确认文件未损坏。"
            )
        }
        return KeePassKdbxPayloadEnvelope(
            headerSummary: parsed.summary,
            headerFields: parsed.fields,
            headerBytes: Data(data[0..<payloadStart]),
            headerByteRange: 0..<payloadStart,
            encryptedPayload: Data(data[payloadStart..<data.count])
        )
    }

    public static func parseKdbxPayloadCryptoInputs(
        from envelope: KeePassKdbxPayloadEnvelope
    ) -> KeePassKdbxPayloadCryptoInputs {
        let headerFields = envelope.headerFields
        return KeePassKdbxPayloadCryptoInputs(
            masterSeed: headerFields[kdbxMasterSeedHeaderField],
            encryptionIV: headerFields[kdbxEncryptionIVHeaderField],
            innerRandomStreamKey: headerFields[kdbxInnerRandomStreamKeyHeaderField],
            streamStartBytes: headerFields[kdbxStreamStartBytesHeaderField],
            innerRandomStreamID: headerFields[kdbxInnerRandomStreamIDHeaderField].flatMap {
                littleEndianUInt32(from: $0, at: 0)
            }
        )
    }

    private static func parseKdbxHeaderSummary(_ data: Data) -> KeePassHeaderSummary? {
        guard data.starts(with: kdbxSignature),
              data.count >= kdbxVersionOffset + kdbxVersionByteCount else {
            return nil
        }
        guard let rawVersion = littleEndianUInt32(from: data, at: kdbxVersionOffset) else {
            return nil
        }
        let minor = Int(rawVersion & 0xFFFF)
        let major = Int((rawVersion >> 16) & 0xFFFF)
        let formatVersion: KeePassKdbxFormatVersion
        switch major {
        case 3:
            formatVersion = .kdbx3
        case 4:
            formatVersion = .kdbx4
        default:
            formatVersion = .unknown
        }
        let headerFields = parseKdbxHeaderFields(data, formatVersion: formatVersion)?.fields ?? [:]
        return KeePassHeaderSummary(
            majorVersion: major == 0 ? nil : major,
            minorVersion: minor,
            formatVersion: formatVersion,
            cryptoSummary: cryptoSummary(from: headerFields, formatVersion: formatVersion),
            kdfParameters: kdfParameters(from: headerFields, formatVersion: formatVersion)
        )
    }

    private static func parseKdbxHeader(_ data: Data) -> ParsedKdbxHeader? {
        guard data.starts(with: kdbxSignature),
              data.count >= kdbxVersionOffset + kdbxVersionByteCount else {
            return nil
        }
        guard let rawVersion = littleEndianUInt32(from: data, at: kdbxVersionOffset) else {
            return nil
        }
        let minor = Int(rawVersion & 0xFFFF)
        let major = Int((rawVersion >> 16) & 0xFFFF)
        let formatVersion: KeePassKdbxFormatVersion
        switch major {
        case 3:
            formatVersion = .kdbx3
        case 4:
            formatVersion = .kdbx4
        default:
            formatVersion = .unknown
        }
        guard let parsedFields = parseKdbxHeaderFields(data, formatVersion: formatVersion) else {
            return nil
        }
        let summary = KeePassHeaderSummary(
            majorVersion: major == 0 ? nil : major,
            minorVersion: minor,
            formatVersion: formatVersion,
            cryptoSummary: cryptoSummary(from: parsedFields.fields, formatVersion: formatVersion),
            kdfParameters: kdfParameters(from: parsedFields.fields, formatVersion: formatVersion)
        )
        return ParsedKdbxHeader(
            summary: summary,
            fields: parsedFields.fields,
            headerEndOffset: parsedFields.headerEndOffset
        )
    }

    private static func parseKdbxHeaderFields(
        _ data: Data,
        formatVersion: KeePassKdbxFormatVersion
    ) -> ParsedKdbxHeaderFields? {
        let lengthByteCount: Int
        switch formatVersion {
        case .kdbx3:
            lengthByteCount = 2
        case .kdbx4:
            lengthByteCount = 4
        case .unknown:
            return nil
        }

        var fields: [UInt8: Data] = [:]
        var index = kdbxHeaderStartOffset
        while index < data.count {
            let fieldID = data[index]
            index += 1

            guard index + lengthByteCount <= data.count else {
                return nil
            }

            let fieldLength: UInt32?
            if lengthByteCount == 2 {
                fieldLength = littleEndianUInt16(from: data, at: index).map(UInt32.init)
            } else {
                fieldLength = littleEndianUInt32(from: data, at: index)
            }
            guard let fieldLength else {
                return nil
            }
            index += lengthByteCount

            let valueLength = Int(fieldLength)
            guard index + valueLength <= data.count else {
                return nil
            }
            let value = Data(data[index..<index + valueLength])
            index += valueLength

            if fieldID == kdbxEndHeaderField {
                return ParsedKdbxHeaderFields(fields: fields, headerEndOffset: index)
            }
            fields[fieldID] = value
        }
        return nil
    }

    private static func cryptoSummary(
        from headerFields: [UInt8: Data],
        formatVersion: KeePassKdbxFormatVersion
    ) -> KeePassKdbxCryptoSummary? {
        let summary = KeePassKdbxCryptoSummary(
            cipher: headerFields[kdbxCipherIDHeaderField].flatMap(cipherAlgorithm),
            compression: headerFields[kdbxCompressionFlagsHeaderField].flatMap(compressionAlgorithm),
            kdf: headerFields[kdbxKdfParametersHeaderField].flatMap(kdfAlgorithm)
                ?? legacyKdbx3KdfAlgorithm(from: headerFields, formatVersion: formatVersion)
        )
        return summary.displaySummary.isEmpty ? nil : summary
    }

    private static func cipherAlgorithm(from data: Data) -> KeePassKdbxCipherAlgorithm? {
        guard !data.isEmpty else {
            return nil
        }
        switch data {
        case kdbxAes256CipherUUID:
            return .aes256
        case kdbxChaCha20CipherUUID:
            return .chacha20
        case kdbxTwofishCipherUUID:
            return .twofish
        default:
            return .unknown(hexString(data))
        }
    }

    private static func compressionAlgorithm(from data: Data) -> KeePassKdbxCompressionAlgorithm? {
        guard let flags = littleEndianUInt32(from: data, at: 0) else {
            return data.isEmpty ? nil : .unknown(0)
        }
        switch flags {
        case 0:
            return KeePassKdbxCompressionAlgorithm.none
        case 1:
            return .gzip
        default:
            return .unknown(flags)
        }
    }

    private static func kdfAlgorithm(from data: Data) -> KeePassKdbxKdfAlgorithm? {
        guard let uuid = parseKdbxVariantDictionary(data).byteArray(named: "$UUID"),
              !uuid.isEmpty else {
            return nil
        }
        return kdfAlgorithm(uuid: uuid)
    }

    private static func kdfParameters(
        from headerFields: [UInt8: Data],
        formatVersion: KeePassKdbxFormatVersion
    ) -> KeePassKdbxKdfParameters? {
        if let legacy = legacyKdbx3KdfParameters(from: headerFields, formatVersion: formatVersion) {
            return legacy
        }
        guard let data = headerFields[kdbxKdfParametersHeaderField] else {
            return nil
        }
        let dictionary = parseKdbxVariantDictionary(data)
        guard let uuid = dictionary.byteArray(named: "$UUID") else {
            return nil
        }
        let algorithm = kdfAlgorithm(uuid: uuid)
        switch algorithm {
        case .argon2d, .argon2id:
            return KeePassKdbxKdfParameters(
                algorithm: algorithm,
                argon2: KeePassKdbxArgon2Parameters(
                    salt: dictionary.byteArray(named: "S"),
                    iterations: dictionary.uint64(named: "I"),
                    memoryBytes: dictionary.uint64(named: "M"),
                    parallelism: dictionary.uint32(named: "P"),
                    version: dictionary.uint32(named: "V")
                )
            )
        case .aesKdf:
            return KeePassKdbxKdfParameters(
                algorithm: algorithm,
                aesKdf: KeePassKdbxAesKdfParameters(
                    seed: dictionary.byteArray(named: "S"),
                    rounds: dictionary.uint64(named: "R")
                )
            )
        case .unknown:
            return KeePassKdbxKdfParameters(algorithm: algorithm)
        }
    }

    private static func legacyKdbx3KdfAlgorithm(
        from headerFields: [UInt8: Data],
        formatVersion: KeePassKdbxFormatVersion
    ) -> KeePassKdbxKdfAlgorithm? {
        guard formatVersion == .kdbx3,
              headerFields[kdbxTransformSeedHeaderField] != nil || headerFields[kdbxTransformRoundsHeaderField] != nil else {
            return nil
        }
        return .aesKdf
    }

    private static func legacyKdbx3KdfParameters(
        from headerFields: [UInt8: Data],
        formatVersion: KeePassKdbxFormatVersion
    ) -> KeePassKdbxKdfParameters? {
        guard legacyKdbx3KdfAlgorithm(from: headerFields, formatVersion: formatVersion) == .aesKdf else {
            return nil
        }
        return KeePassKdbxKdfParameters(
            algorithm: .aesKdf,
            aesKdf: KeePassKdbxAesKdfParameters(
                seed: headerFields[kdbxTransformSeedHeaderField],
                rounds: headerFields[kdbxTransformRoundsHeaderField].flatMap {
                    littleEndianUInt64(from: $0, at: 0)
                }
            )
        )
    }

    private static func kdfAlgorithm(uuid: Data) -> KeePassKdbxKdfAlgorithm {
        switch uuid {
        case kdbxAesKdfUUID:
            return .aesKdf
        case kdbxArgon2dKdfUUID:
            return .argon2d
        case kdbxArgon2idKdfUUID:
            return .argon2id
        default:
            return .unknown(hexString(uuid))
        }
    }

    private static func parseKdbxVariantDictionary(_ data: Data) -> [String: KdbxVariantValue] {
        guard data.count >= 2 else {
            return [:]
        }
        var values: [String: KdbxVariantValue] = [:]
        var index = 2
        while index < data.count {
            let valueType = data[index]
            index += 1

            if valueType == 0 {
                return values
            }

            guard let keyLengthRaw = littleEndianUInt32(from: data, at: index) else {
                return values
            }
            index += 4

            let keyLength = Int(keyLengthRaw)
            guard index + keyLength <= data.count else {
                return values
            }
            let keyData = Data(data[index..<index + keyLength])
            index += keyLength

            guard let valueLengthRaw = littleEndianUInt32(from: data, at: index) else {
                return values
            }
            index += 4

            let valueLength = Int(valueLengthRaw)
            guard index + valueLength <= data.count else {
                return values
            }
            let value = Data(data[index..<index + valueLength])
            index += valueLength

            guard let key = String(data: keyData, encoding: .utf8) else {
                continue
            }
            switch valueType {
            case 0x04:
                if let number = littleEndianUInt32(from: value, at: 0), value.count == 4 {
                    values[key] = .uint32(number)
                }
            case 0x05:
                if let number = littleEndianUInt64(from: value, at: 0), value.count == 8 {
                    values[key] = .uint64(number)
                }
            case 0x42:
                values[key] = .byteArray(value)
            default:
                continue
            }
        }
        return values
    }

    private static func littleEndianUInt16(from data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else {
            return nil
        }
        var value: UInt16 = 0
        for byteOffset in 0..<2 {
            value |= UInt16(data[offset + byteOffset]) << UInt16(byteOffset * 8)
        }
        return value
    }

    private static func littleEndianUInt32(from data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else {
            return nil
        }
        var value: UInt32 = 0
        for byteOffset in 0..<4 {
            value |= UInt32(data[offset + byteOffset]) << UInt32(byteOffset * 8)
        }
        return value
    }

    private static func littleEndianUInt64(from data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else {
            return nil
        }
        var value: UInt64 = 0
        for byteOffset in 0..<8 {
            value |= UInt64(data[offset + byteOffset]) << UInt64(byteOffset * 8)
        }
        return value
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}

private extension Dictionary where Key == String, Value == KeePassFormatInspector.KdbxVariantValue {
    func byteArray(named name: String) -> Data? {
        guard case let .byteArray(value) = self[name] else {
            return nil
        }
        return value
    }

    func uint32(named name: String) -> UInt32? {
        guard case let .uint32(value) = self[name] else {
            return nil
        }
        return value
    }

    func uint64(named name: String) -> UInt64? {
        guard case let .uint64(value) = self[name] else {
            return nil
        }
        return value
    }
}

private extension String {
    var isLikelyLegacyKdbExtension: Bool {
        let lower = lowercased()
        return lower.hasSuffix(".kdb") && !lower.hasSuffix(".kdbx")
    }

    var sanitizedKeePassFileName: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

public enum LocalAttachmentContentStoreError: Error, Sendable, Equatable, LocalizedError {
    case missingLocalPath
    case missingBlob(String)

    public var errorDescription: String? {
        switch self {
        case .missingLocalPath:
            return "附件缺少本地密文路径。"
        case .missingBlob:
            return "附件密文尚未保存在本机。"
        }
    }
}

public protocol LocalAttachmentContentStore: Sendable {
    func saveEncryptedBlob(_ data: Data, vaultID: String, localPath: String) throws -> String
    func encryptedBlobExists(vaultID: String, localPath: String) -> Bool
    func encryptedBlobData(vaultID: String, localPath: String) throws -> Data
}

public enum LocalAttachmentContentCryptoError: Error, Sendable, Equatable, LocalizedError {
    case invalidContentEncryptionKeyLength
    case invalidEncryptedBlob
    case authenticationFailed
    case unsupportedWrappedContentEncryptionKey

    public var errorDescription: String? {
        switch self {
        case .invalidContentEncryptionKeyLength:
            return "附件内容密钥长度无效。"
        case .invalidEncryptedBlob:
            return "附件密文格式无效。"
        case .authenticationFailed:
            return "附件解密认证失败。"
        case .unsupportedWrappedContentEncryptionKey:
            return "附件内容密钥包裹格式暂不支持。"
        }
    }
}

public enum AndroidAttachmentContentWrappingKey: Sendable, Equatable {
    case mdk(Data)
    case legacyKey(Data)
    case legacyMasterKeyDescription(String)

    fileprivate var keyMaterial: Data {
        switch self {
        case .mdk(let data), .legacyKey(let data):
            return data
        case .legacyMasterKeyDescription(let description):
            var bytes = Array(description.utf8)
            if bytes.count < LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount {
                bytes.append(
                    contentsOf: Array(
                        repeating: 0,
                        count: LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount - bytes.count
                    )
                )
            }
            return Data(bytes.prefix(LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount))
        }
    }
}

public enum AndroidWrappedAttachmentContentKeyUnwrapper {
    private static let mdkPrefix = "MDK|"
    private static let v2Prefix = "V2|"

    public static func unwrap(
        _ wrappedContentEncryptionKey: String,
        using wrappingKey: AndroidAttachmentContentWrappingKey
    ) throws -> Data {
        let trimmed = wrappedContentEncryptionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalAttachmentContentCryptoError.invalidEncryptedBlob
        }
        if trimmed.hasPrefix(v2Prefix) {
            throw LocalAttachmentContentCryptoError.unsupportedWrappedContentEncryptionKey
        }

        let payloadBase64: String
        if trimmed.hasPrefix(mdkPrefix) {
            payloadBase64 = String(trimmed.dropFirst(mdkPrefix.count))
        } else {
            payloadBase64 = trimmed
        }

        let keyMaterial = wrappingKey.keyMaterial
        guard keyMaterial.count == LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount else {
            throw LocalAttachmentContentCryptoError.invalidContentEncryptionKeyLength
        }
        guard let combined = Data(base64Encoded: payloadBase64, options: [.ignoreUnknownCharacters]),
              combined.count >= LocalAttachmentContentDecryptor.androidIVByteCount
                + LocalAttachmentContentDecryptor.androidAuthenticationTagByteCount
        else {
            throw LocalAttachmentContentCryptoError.invalidEncryptedBlob
        }

        let nonceData = combined.prefix(LocalAttachmentContentDecryptor.androidIVByteCount)
        let sealedPayload = combined.dropFirst(LocalAttachmentContentDecryptor.androidIVByteCount)
        let ciphertext = sealedPayload.dropLast(LocalAttachmentContentDecryptor.androidAuthenticationTagByteCount)
        let tag = sealedPayload.suffix(LocalAttachmentContentDecryptor.androidAuthenticationTagByteCount)

        let decryptedBase64: Data
        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: Data(ciphertext),
                tag: Data(tag)
            )
            decryptedBase64 = try AES.GCM.open(
                sealedBox,
                using: SymmetricKey(data: keyMaterial)
            )
        } catch is CryptoKitError {
            throw LocalAttachmentContentCryptoError.authenticationFailed
        } catch {
            throw LocalAttachmentContentCryptoError.invalidEncryptedBlob
        }

        guard let base64String = String(data: decryptedBase64, encoding: .utf8),
              let cek = Data(base64Encoded: base64String, options: [.ignoreUnknownCharacters]),
              cek.count == LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount
        else {
            throw LocalAttachmentContentCryptoError.invalidContentEncryptionKeyLength
        }
        return cek
    }
}

public enum LocalAttachmentContentDecryptor {
    public static let androidIVByteCount = 12
    public static let androidContentEncryptionKeyByteCount = 32
    public static let androidAuthenticationTagByteCount = 16

    public static func decryptAndroidLocalBlob(
        _ encryptedBlob: Data,
        contentEncryptionKey: Data
    ) throws -> Data {
        guard contentEncryptionKey.count == androidContentEncryptionKeyByteCount else {
            throw LocalAttachmentContentCryptoError.invalidContentEncryptionKeyLength
        }
        guard encryptedBlob.count >= androidIVByteCount + androidAuthenticationTagByteCount else {
            throw LocalAttachmentContentCryptoError.invalidEncryptedBlob
        }

        let nonceData = encryptedBlob.prefix(androidIVByteCount)
        let sealedPayload = encryptedBlob.dropFirst(androidIVByteCount)
        guard sealedPayload.count >= androidAuthenticationTagByteCount else {
            throw LocalAttachmentContentCryptoError.invalidEncryptedBlob
        }

        let ciphertext = sealedPayload.dropLast(androidAuthenticationTagByteCount)
        let tag = sealedPayload.suffix(androidAuthenticationTagByteCount)

        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: Data(ciphertext),
                tag: Data(tag)
            )
            return try AES.GCM.open(
                sealedBox,
                using: SymmetricKey(data: contentEncryptionKey)
            )
        } catch is CryptoKitError {
            throw LocalAttachmentContentCryptoError.authenticationFailed
        } catch {
            throw LocalAttachmentContentCryptoError.invalidEncryptedBlob
        }
    }
}

public struct FileLocalAttachmentContentStore: LocalAttachmentContentStore, @unchecked Sendable {
    private let baseDirectory: URL?
    private let fileManager: FileManager

    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    public func saveEncryptedBlob(_ data: Data, vaultID: String, localPath: String) throws -> String {
        let vaultDirectory = try storageRoot()
            .appendingPathComponent(sanitizedPathComponent(vaultID), isDirectory: true)
        try fileManager.createDirectory(at: vaultDirectory, withIntermediateDirectories: true)

        let relativePath = sanitizedPathComponent(localPath)
        let fileURL = vaultDirectory.appendingPathComponent(relativePath, isDirectory: false)
        try data.write(to: fileURL, options: [.atomic])
        return relativePath
    }

    public func encryptedBlobExists(vaultID: String, localPath: String) -> Bool {
        guard let fileURL = try? encryptedBlobURL(vaultID: vaultID, localPath: localPath) else {
            return false
        }
        return fileManager.isReadableFile(atPath: fileURL.path)
    }

    public func encryptedBlobData(vaultID: String, localPath: String) throws -> Data {
        let fileURL = try encryptedBlobURL(vaultID: vaultID, localPath: localPath)
        guard fileManager.isReadableFile(atPath: fileURL.path) else {
            throw LocalAttachmentContentStoreError.missingBlob(localPath)
        }
        return try Data(contentsOf: fileURL)
    }

    private func encryptedBlobURL(vaultID: String, localPath: String) throws -> URL {
        let relativePath = sanitizedPathComponent(localPath)
        guard !relativePath.isEmpty else {
            throw LocalAttachmentContentStoreError.missingLocalPath
        }
        return try storageRoot()
            .appendingPathComponent(sanitizedPathComponent(vaultID), isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
    }

    private func storageRoot() throws -> URL {
        if let baseDirectory {
            return baseDirectory
        }
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("Monica", isDirectory: true)
                .appendingPathComponent("AttachmentContent", isDirectory: true)
        }
        return applicationSupport
            .appendingPathComponent("Monica", isDirectory: true)
            .appendingPathComponent("AttachmentContent", isDirectory: true)
    }

    private func sanitizedPathComponent(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? value
        let sanitized = normalized.unicodeScalars
            .map { scalar -> String in
                switch scalar.value {
                case 48...57, 65...90, 97...122:
                    String(scalar)
                case 45, 46, 95:
                    String(scalar)
                default:
                    "_"
                }
            }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return sanitized.isEmpty ? UUID().uuidString + ".enc" : sanitized
    }
}

public enum VaultSource: String, Sendable, Equatable, CaseIterable {
    case mdbx
    case keepass
    case bitwarden
    case androidBackup
    case csvImport

    public var displayName: String {
        switch self {
        case .mdbx:
            return "MDBX"
        case .keepass:
            return "KeePass"
        case .bitwarden:
            return "Bitwarden"
        case .androidBackup:
            return "Android 备份"
        case .csvImport:
            return "CSV 导入"
        }
    }

    public static let phaseOneSources: [VaultSource] = [.mdbx]
    public static let longTermSources: [VaultSource] = [
        .mdbx,
        .keepass,
        .bitwarden,
        .androidBackup,
        .csvImport
    ]
}

public enum UnifiedVaultItemKind: String, Sendable, Equatable, CaseIterable {
    case login
    case totp
    case note
    case card
    case identity
    case passkey
    case sshKey
    case apiToken
    case wifi
    case send
    case attachmentRef

    public var displayName: String {
        switch self {
        case .login:
            return "密码"
        case .totp:
            return "验证器"
        case .note:
            return "笔记"
        case .card:
            return "银行卡"
        case .identity:
            return "证件"
        case .passkey:
            return "通行密钥"
        case .sshKey:
            return "SSH 密钥"
        case .apiToken:
            return "API Token"
        case .wifi:
            return "Wi-Fi"
        case .send:
            return "安全发送"
        case .attachmentRef:
            return "附件"
        }
    }

    public static let phaseOneKinds: [UnifiedVaultItemKind] = [
        .login,
        .totp,
        .note,
        .card,
        .identity
    ]

    public static let fullAndroidParityKinds: [UnifiedVaultItemKind] = [
        .login,
        .card,
        .identity,
        .totp,
        .passkey,
        .note,
        .sshKey,
        .apiToken,
        .wifi,
        .send,
        .attachmentRef
    ]
}

public struct UnifiedVaultItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let source: VaultSource
    public let kind: UnifiedVaultItemKind
    public let title: String
    public let subtitle: String
    public let searchableText: String
    public let isFavorite: Bool
    public let isDeleted: Bool

    public init(
        id: String,
        source: VaultSource,
        kind: UnifiedVaultItemKind,
        title: String,
        subtitle: String,
        searchableText: String,
        isFavorite: Bool,
        isDeleted: Bool
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.searchableText = searchableText
        self.isFavorite = isFavorite
        self.isDeleted = isDeleted
    }

    public var listTitle: String { title }
    public var listSubtitle: String { subtitle }

    public func matches(_ query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return true
        }
        return searchableText.localizedCaseInsensitiveContains(trimmedQuery)
    }
}

public enum VaultCSVItemDraft: Sendable, Equatable {
    case login(LocalLoginEntryDraft)
    case note(LocalNoteEntryDraft)
    case totp(LocalTotpEntryDraft)
    case card(LocalCardEntryDraft)
    case identity(LocalIdentityEntryDraft)
    case passkey(LocalPasskeyEntryDraft)
    case sshKey(LocalSshKeyEntryDraft)
    case apiToken(LocalApiTokenEntryDraft)
    case wifi(LocalWifiEntryDraft)
    case send(LocalSendEntryDraft)

    public var kind: UnifiedVaultItemKind {
        switch self {
        case .login: return .login
        case .note: return .note
        case .totp: return .totp
        case .card: return .card
        case .identity: return .identity
        case .passkey: return .passkey
        case .sshKey: return .sshKey
        case .apiToken: return .apiToken
        case .wifi: return .wifi
        case .send: return .send
        }
    }
}

public struct AndroidBackupImportedItem: Sendable, Equatable {
    public let sourceID: Int64?
    public let draft: VaultCSVItemDraft

    public init(sourceID: Int64?, draft: VaultCSVItemDraft) {
        self.sourceID = sourceID
        self.draft = draft
    }
}

public enum VaultCSVImportIssueCode: Sendable, Equatable {
    case emptyCSV
    case missingKindColumn
    case unsupportedKind
    case missingRequiredField
    case invalidNumber
    case invalidBoolean
    case malformedCSV
}

public struct VaultCSVImportIssue: Sendable, Equatable {
    public let row: Int
    public let code: VaultCSVImportIssueCode
    public let field: String?
    public let message: String

    public init(row: Int, code: VaultCSVImportIssueCode, field: String?, message: String) {
        self.row = row
        self.code = code
        self.field = field
        self.message = message
    }
}

public struct VaultCSVImportReport: Sendable, Equatable {
    public let items: [VaultCSVItemDraft]
    public let issues: [VaultCSVImportIssue]

    public init(items: [VaultCSVItemDraft], issues: [VaultCSVImportIssue]) {
        self.items = items
        self.issues = issues
    }
}

public enum AndroidBackupIssueCode: Sendable, Equatable {
    case malformedZip
    case encryptedBackupUnsupported
    case encryptedBackupDecryptionFailed
    case unsafeEntryPath
    case unsupportedEntry
    case malformedJSON
}

public struct AndroidBackupImportIssue: Sendable, Equatable {
    public let entryPath: String
    public let code: AndroidBackupIssueCode
    public let message: String

    public init(entryPath: String, code: AndroidBackupIssueCode, message: String) {
        self.entryPath = entryPath
        self.code = code
        self.message = message
    }
}

public struct AndroidBackupAttachmentMetadata: Sendable, Equatable, Identifiable {
    public let id: String
    public let parentPasswordID: Int64
    public let fileName: String
    public let mediaType: String
    public let originalSize: Int64
    public let contentHash: String
    public let wrappedContentEncryptionKey: String
    public let localPath: String
    public let blobEntryPath: String?
    public let encryptedBlob: Data?
    public let createdAt: Int64
    public let updatedAt: Int64

    public init(
        id: String,
        parentPasswordID: Int64,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        contentHash: String,
        wrappedContentEncryptionKey: String,
        localPath: String,
        blobEntryPath: String?,
        encryptedBlob: Data? = nil,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.parentPasswordID = parentPasswordID
        self.fileName = fileName
        self.mediaType = mediaType
        self.originalSize = originalSize
        self.contentHash = contentHash
        self.wrappedContentEncryptionKey = wrappedContentEncryptionKey
        self.localPath = localPath
        self.blobEntryPath = blobEntryPath
        self.encryptedBlob = encryptedBlob
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AndroidBackupImportReport: Sendable, Equatable {
    public let items: [VaultCSVItemDraft]
    public let importedItems: [AndroidBackupImportedItem]
    public let attachments: [AndroidBackupAttachmentMetadata]
    public let issues: [AndroidBackupImportIssue]

    public init(
        items: [VaultCSVItemDraft],
        importedItems: [AndroidBackupImportedItem]? = nil,
        attachments: [AndroidBackupAttachmentMetadata] = [],
        issues: [AndroidBackupImportIssue]
    ) {
        self.items = items
        self.importedItems = importedItems ?? items.map { AndroidBackupImportedItem(sourceID: nil, draft: $0) }
        self.attachments = attachments
        self.issues = issues
    }
}

public enum AndroidBackupCodec {
    private static let encryptedBackupMagic = Data("MONICA_ENC_V1".utf8)
    private static let encryptedBackupSaltLength = 32
    private static let encryptedBackupIVLength = 12
    private static let encryptedBackupPBKDF2Iterations = 100_000
    private static let encryptedBackupKeyLength = 32
    private static let aesGCMTagLength = 16
    public static let encryptedBackupUnsupportedMessage = "Android 加密备份暂未支持解密，请先从 Android 导出未加密 .zip 后再导入。"
    public static let encryptedBackupDecryptionFailedMessage = "Android 加密备份解密失败，请检查密码或文件是否损坏。"

    public static func importItems(
        from zipData: Data,
        fileName: String? = nil,
        decryptPassword: String? = nil
    ) throws -> AndroidBackupImportReport {
        if isEncryptedBackup(zipData, fileName: fileName) {
            guard let decryptPassword, !decryptPassword.isEmpty else {
                return AndroidBackupImportReport(
                    items: [],
                    issues: [
                        AndroidBackupImportIssue(
                            entryPath: fileName ?? "backup",
                            code: .encryptedBackupUnsupported,
                            message: encryptedBackupUnsupportedMessage
                        )
                    ]
                )
            }

            do {
                let decryptedZip = try decryptAndroidEncryptedBackup(zipData, password: decryptPassword)
                return try importItems(from: decryptedZip)
            } catch {
                return AndroidBackupImportReport(
                    items: [],
                    issues: [
                        AndroidBackupImportIssue(
                            entryPath: fileName ?? "backup",
                            code: .encryptedBackupDecryptionFailed,
                            message: encryptedBackupDecryptionFailedMessage
                        )
                    ]
                )
            }
        }

        let archive = try Archive(data: zipData, accessMode: .read)
        return try importItems(from: archive)
    }

    private static func importItems(from archive: Archive) throws -> AndroidBackupImportReport {
        var orderedItems: [(order: Int, index: Int, importedItem: AndroidBackupImportedItem)] = []
        var issues: [AndroidBackupImportIssue] = []
        var legacyCSVFiles: [(path: String, data: Data, index: Int)] = []
        var jsonBackedKinds = Set<BackupKind>()
        var attachmentManifest: (path: String, data: Data)?
        var attachmentBlobDataByPath: [String: Data] = [:]
        var index = 0

        for entry in archive where entry.type == .file {
            let path = normalizedPath(entry.path)
            guard isSafeEntryPath(path) else {
                issues.append(issue(entryPath: entry.path, code: .unsafeEntryPath, detail: "ZIP 条目路径不安全"))
                continue
            }
            if isAttachmentBlob(path) {
                var data = Data()
                _ = try archive.extract(entry) { chunk in
                    data.append(chunk)
                }
                attachmentBlobDataByPath[path] = data
                index += 1
                continue
            }
            guard path.hasSuffix(".json") || path.hasSuffix(".csv") else {
                continue
            }

            var data = Data()
            _ = try archive.extract(entry) { chunk in
                data.append(chunk)
            }

            if isAttachmentManifest(path) {
                attachmentManifest = (path: path, data: data)
                index += 1
                continue
            }

            if path.hasSuffix(".csv") {
                legacyCSVFiles.append((path: path, data: data, index: index))
                index += 1
                continue
            }

            guard let kind = kind(for: path) else {
                continue
            }
            guard let importedItem = parseItem(kind: kind, data: data, path: path, issues: &issues) else {
                continue
            }
            jsonBackedKinds.insert(kind)
            orderedItems.append((order: order(for: path, kind: kind), index: index, importedItem: importedItem))
            index += 1
        }

        for csvFile in legacyCSVFiles {
            let parsedItems = parseLegacyCSVItems(
                path: csvFile.path,
                data: csvFile.data,
                jsonBackedKinds: jsonBackedKinds,
                issues: &issues
            )
            for item in parsedItems {
                let kind = backupKind(for: item)
                orderedItems.append(
                    (
                        order: kindPriority(kind),
                        index: index,
                        importedItem: AndroidBackupImportedItem(sourceID: nil, draft: item)
                    )
                )
                index += 1
            }
        }

        let importedItems = orderedItems
            .sorted { lhs, rhs in
                if lhs.order == rhs.order {
                    return lhs.index < rhs.index
                }
                return lhs.order < rhs.order
            }
            .map(\.importedItem)
        let items = importedItems.map(\.draft)
        let attachments = parseAttachmentManifest(
            attachmentManifest,
            blobDataByPath: attachmentBlobDataByPath,
            issues: &issues
        )
        return AndroidBackupImportReport(
            items: items,
            importedItems: importedItems,
            attachments: attachments,
            issues: issues
        )
    }

    private static func decryptAndroidEncryptedBackup(_ data: Data, password: String) throws -> Data {
        let headerLength = encryptedBackupMagic.count
        let minimumLength = headerLength
            + encryptedBackupSaltLength
            + encryptedBackupIVLength
            + aesGCMTagLength
        guard data.count >= minimumLength, data.starts(with: encryptedBackupMagic) else {
            throw AndroidBackupEncryptedArchiveError.invalidFormat
        }

        var offset = headerLength
        let salt = Data(data[offset..<offset + encryptedBackupSaltLength])
        offset += encryptedBackupSaltLength
        let nonceData = Data(data[offset..<offset + encryptedBackupIVLength])
        offset += encryptedBackupIVLength
        let encryptedPayload = Data(data[offset...])
        guard encryptedPayload.count >= aesGCMTagLength else {
            throw AndroidBackupEncryptedArchiveError.invalidFormat
        }

        let keyData = try pbkdf2SHA256(
            password: Data(password.utf8),
            salt: salt,
            iterations: encryptedBackupPBKDF2Iterations,
            keyLength: encryptedBackupKeyLength
        )
        let ciphertext = encryptedPayload.prefix(encryptedPayload.count - aesGCMTagLength)
        let tag = encryptedPayload.suffix(aesGCMTagLength)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        )
        return try AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData))
    }

    private static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) throws -> Data {
        guard iterations > 0, keyLength > 0 else {
            throw AndroidBackupEncryptedArchiveError.invalidFormat
        }

        let passwordKey = SymmetricKey(data: password)
        let hmacLength = SHA256.byteCount
        let blockCount = Int(ceil(Double(keyLength) / Double(hmacLength)))
        var derivedKey = Data()

        for blockIndex in 1...blockCount {
            var blockInput = salt
            blockInput.append(UInt8((blockIndex >> 24) & 0xff))
            blockInput.append(UInt8((blockIndex >> 16) & 0xff))
            blockInput.append(UInt8((blockIndex >> 8) & 0xff))
            blockInput.append(UInt8(blockIndex & 0xff))

            var u = Data(HMAC<SHA256>.authenticationCode(for: blockInput, using: passwordKey))
            var t = u
            if iterations > 1 {
                for _ in 2...iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: passwordKey))
                    for index in t.indices {
                        t[index] ^= u[index]
                    }
                }
            }
            derivedKey.append(t)
        }

        return derivedKey.prefix(keyLength)
    }

    private enum AndroidBackupEncryptedArchiveError: Error {
        case invalidFormat
    }

    private static func isEncryptedBackup(_ data: Data, fileName: String?) -> Bool {
        if fileName?.lowercased().hasSuffix(".enc.zip") == true {
            return true
        }
        return data.starts(with: encryptedBackupMagic)
    }

    public static func exportItems(_ items: [VaultCSVItemDraft], folderName: String = "Imported") throws -> Data {
        var entries: [String: String] = [:]
        for (index, item) in items.enumerated() {
            let id = index + 1
            let timestamp = 1_797_000_000_000 + id
            let path = entryPath(for: item, folderName: folderName, id: id, timestamp: timestamp)
            entries[path] = try jsonString(for: item, id: id, timestamp: timestamp, folderName: folderName)
        }
        return try exportZip(entries: entries)
    }

    public static func exportZip(entries: [String: String]) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        for path in entries.keys.sorted() {
            guard let content = entries[path] else { continue }
            let data = Data(content.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                guard start < data.count else { return Data() }
                let end = min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
        }
        return archive.data ?? Data()
    }

    public static func inspectEntryNames(in zipData: Data) throws -> [String] {
        let archive = try Archive(data: zipData, accessMode: .read)
        return archive.map(\.path)
    }

    private enum BackupKind: Hashable {
        case password
        case totp
        case note
        case card
        case identity
        case passkey
    }

    private static func kind(for path: String) -> BackupKind? {
        switch true {
        case path.contains("/passwords/") || path.hasPrefix("passwords/"):
            return .password
        case path.contains("/authenticators/") || path.hasPrefix("authenticators/") || path.contains("/totp/") || path.hasPrefix("totp/"):
            return .totp
        case path.contains("/notes/") || path.hasPrefix("notes/"):
            return .note
        case path.contains("/bank_cards/") || path.hasPrefix("bank_cards/"):
            return .card
        case path.contains("/documents/") || path.hasPrefix("documents/"):
            return .identity
        case path.contains("/passkeys/") || path.hasPrefix("passkeys/"):
            return .passkey
        default:
            return nil
        }
    }

    private enum LegacySecureCSVRole {
        case generic
        case notesOnly
        case totpOnly
        case cardsAndDocumentsOnly
    }

    private struct AttachmentManifest: Decodable {
        let version: Int
        let entries: [AttachmentEntry]
    }

    private struct AttachmentEntry: Decodable {
        let parentPasswordId: Int64
        let fileName: String
        let mimeType: String
        let sizeBytes: Int64
        let sha256Hex: String?
        let wrappedCek: String
        let localPath: String
        let createdAt: Int64
        let updatedAt: Int64
    }

    private static func order(for path: String, kind: BackupKind) -> Int {
        let fileName = path.split(separator: "/").last.map(String.init) ?? path
        if let firstNumber = fileName.split(whereSeparator: { !$0.isNumber }).compactMap({ Int($0) }).first {
            return firstNumber
        }
        return 1_000_000 + kindPriority(kind)
    }

    private static func kindPriority(_ kind: BackupKind) -> Int {
        switch kind {
        case .password: return 0
        case .totp: return 1
        case .note: return 2
        case .card: return 3
        case .identity: return 4
        case .passkey: return 5
        }
    }

    private static func backupKind(for item: VaultCSVItemDraft) -> BackupKind {
        switch item {
        case .login, .sshKey, .apiToken, .wifi:
            return .password
        case .totp:
            return .totp
        case .note, .send:
            return .note
        case .card:
            return .card
        case .identity:
            return .identity
        case .passkey:
            return .passkey
        }
    }

    private static func parseAttachmentManifest(
        _ manifest: (path: String, data: Data)?,
        blobDataByPath: [String: Data],
        issues: inout [AndroidBackupImportIssue]
    ) -> [AndroidBackupAttachmentMetadata] {
        guard let manifest else { return [] }
        do {
            let decoded = try JSONDecoder().decode(AttachmentManifest.self, from: manifest.data)
            guard decoded.version == 1 else {
                issues.append(issue(entryPath: manifest.path, code: .unsupportedEntry, detail: "不支持的附件 manifest 版本"))
                return []
            }
            return decoded.entries.enumerated().map { offset, entry in
                let blob = attachmentBlob(for: entry.localPath, in: blobDataByPath)
                return AndroidBackupAttachmentMetadata(
                    id: "android-attachment-\(entry.parentPasswordId)-\(offset)",
                    parentPasswordID: entry.parentPasswordId,
                    fileName: entry.fileName,
                    mediaType: entry.mimeType,
                    originalSize: entry.sizeBytes,
                    contentHash: entry.sha256Hex ?? "",
                    wrappedContentEncryptionKey: entry.wrappedCek,
                    localPath: entry.localPath,
                    blobEntryPath: blob?.path,
                    encryptedBlob: blob?.data,
                    createdAt: entry.createdAt,
                    updatedAt: entry.updatedAt
                )
            }
        } catch {
            issues.append(issue(entryPath: manifest.path, code: .malformedJSON, detail: "Android 附件 manifest 无法解析"))
            return []
        }
    }

    private static func isAttachmentManifest(_ path: String) -> Bool {
        path.lowercased() == "attachments/attachments_meta.json"
    }

    private static func isAttachmentBlob(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased.hasPrefix("attachments/")
            && lowercased != "attachments/attachments_meta.json"
            && !path.hasSuffix("/")
    }

    private static func attachmentBlob(for localPath: String, in blobDataByPath: [String: Data]) -> (path: String, data: Data)? {
        let fileName = localPath.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? localPath
        let expectedPath = "attachments/\(fileName)"
        if let data = blobDataByPath[expectedPath] {
            return (expectedPath, data)
        }
        guard let matchedPath = blobDataByPath.keys.first(where: { path in
            path.split(separator: "/").last.map(String.init) == fileName
        }) else {
            return nil
        }
        return (matchedPath, blobDataByPath[matchedPath] ?? Data())
    }

    private static func parseLegacyCSVItems(
        path: String,
        data: Data,
        jsonBackedKinds: Set<BackupKind>,
        issues: inout [AndroidBackupImportIssue]
    ) -> [VaultCSVItemDraft] {
        guard let csv = String(data: data, encoding: .utf8) else {
            issues.append(issue(entryPath: path, code: .unsupportedEntry, detail: "旧版 CSV 不是 UTF-8 编码"))
            return []
        }
        do {
            let rows = try parseCSVRows(csv)
            guard let header = rows.first else { return [] }
            let normalizedHeader = header.map { normalizedCSVHeader($0) }
            if isLegacyPasswordCSV(path: path, header: normalizedHeader) {
                guard !jsonBackedKinds.contains(.password) else { return [] }
                return parseLegacyPasswordCSVRows(rows: rows, header: normalizedHeader)
            }
            guard let role = legacySecureCSVRole(path: path, header: normalizedHeader) else {
                return []
            }
            return parseLegacySecureCSVRows(rows: rows, role: role, jsonBackedKinds: jsonBackedKinds, path: path, issues: &issues)
        } catch {
            issues.append(issue(entryPath: path, code: .unsupportedEntry, detail: "旧版 CSV 格式无法解析"))
            return []
        }
    }

    private static func isLegacyPasswordCSV(path: String, header: [String]) -> Bool {
        let fileName = path.split(separator: "/").last.map(String.init) ?? path
        let lowerFileName = fileName.lowercased()
        let headerSet = Set(header)
        return lowerFileName == "passwords.csv"
            || lowerFileName.hasSuffix("_password.csv")
            || (headerSet.contains("name") && headerSet.contains("url") && headerSet.contains("username") && headerSet.contains("password"))
            || (headerSet.contains("title") && headerSet.contains("password"))
    }

    private static func legacySecureCSVRole(path: String, header: [String]) -> LegacySecureCSVRole? {
        let headerSet = Set(header)
        guard headerSet.contains("id"),
              headerSet.contains("type"),
              headerSet.contains("title"),
              headerSet.contains("data")
        else { return nil }

        let fileName = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        if fileName.hasSuffix("_notes.csv") {
            return .notesOnly
        }
        if fileName.hasSuffix("_totp.csv") {
            return .totpOnly
        }
        if fileName.hasSuffix("_cards_docs.csv") {
            return .cardsAndDocumentsOnly
        }
        return .generic
    }

    private static func parseLegacyPasswordCSVRows(rows: [[String]], header: [String]) -> [VaultCSVItemDraft] {
        let headerIndex = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($0.element, $0.offset) })
        return rows.dropFirst().compactMap { row in
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return nil
            }
            let title = csvValue("name", row: row, headerIndex: headerIndex, fallback: csvValue("title", row: row, headerIndex: headerIndex))
            let url = csvValue("url", row: row, headerIndex: headerIndex, fallback: csvValue("website", row: row, headerIndex: headerIndex))
            let username = csvValue("username", row: row, headerIndex: headerIndex, fallback: csvValue("user name", row: row, headerIndex: headerIndex))
            let password = csvValue("password", row: row, headerIndex: headerIndex)
            let notes = csvValue("notes", row: row, headerIndex: headerIndex, fallback: csvValue("note", row: row, headerIndex: headerIndex))

            guard !title.isEmpty || !url.isEmpty || !username.isEmpty else {
                return nil
            }

            return .login(LocalLoginEntryDraft(
                title: title.isEmpty ? url.isEmpty ? username : url : title,
                username: username,
                password: password,
                url: url,
                notes: notes
            ))
        }
    }

    private static func parseLegacySecureCSVRows(
        rows: [[String]],
        role: LegacySecureCSVRole,
        jsonBackedKinds: Set<BackupKind>,
        path: String,
        issues: inout [AndroidBackupImportIssue]
    ) -> [VaultCSVItemDraft] {
        guard let header = rows.first else { return [] }
        let headerIndex = Dictionary(uniqueKeysWithValues: header.map(normalizedCSVHeader).enumerated().map { ($0.element, $0.offset) })
        var items: [VaultCSVItemDraft] = []

        for (rowOffset, row) in rows.dropFirst().enumerated() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                continue
            }
            let rawType = csvValue("type", row: row, headerIndex: headerIndex)
            let title = csvValue("title", row: row, headerIndex: headerIndex)
            let itemData = csvValue("data", row: row, headerIndex: headerIndex)
            let notes = csvValue("notes", row: row, headerIndex: headerIndex)

            guard let kind = resolveLegacySecureKind(rawType: rawType, itemData: itemData, role: role) else {
                if role == .cardsAndDocumentsOnly {
                    issues.append(issue(entryPath: path, code: .unsupportedEntry, detail: "第 \(rowOffset + 2) 行无法识别为卡片或证件"))
                }
                continue
            }
            guard !jsonBackedKinds.contains(kind) else {
                continue
            }
            guard let item = parseLegacySecureItem(kind: kind, title: title, itemData: itemData, notes: notes) else {
                issues.append(issue(entryPath: path, code: .unsupportedEntry, detail: "第 \(rowOffset + 2) 行旧版安全项无法解析"))
                continue
            }
            items.append(item)
        }
        return items
    }

    private static func resolveLegacySecureKind(
        rawType: String,
        itemData: String,
        role: LegacySecureCSVRole
    ) -> BackupKind? {
        switch role {
        case .notesOnly:
            return .note
        case .totpOnly:
            return .totp
        case .cardsAndDocumentsOnly:
            guard let kind = backupKindAlias(rawType) ?? inferSecureKind(from: itemData),
                  kind == .card || kind == .identity
            else { return nil }
            return kind
        case .generic:
            return backupKindAlias(rawType) ?? inferSecureKind(from: itemData)
        }
    }

    private static func backupKindAlias(_ rawType: String) -> BackupKind? {
        let normalized = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "TOTP", "AUTHENTICATOR", "AUTHENTICATORS", "验证器":
            return .totp
        case "BANK_CARD", "BANKCARD", "BANK_CARDS", "BANKCARDS", "CARD", "CARDS", "CREDIT_CARD", "DEBIT_CARD", "卡片", "银行卡":
            return .card
        case "DOCUMENT", "DOCUMENTS", "DOC", "DOCS", "IDENTITY", "ID_CARD", "IDCARD", "PASSPORT", "DRIVER_LICENSE", "证件", "身份":
            return .identity
        case "NOTE", "NOTES", "SECURE_NOTE", "笔记":
            return .note
        default:
            return nil
        }
    }

    private static func inferSecureKind(from itemData: String) -> BackupKind? {
        guard let object = try? JSONObject(jsonString: itemData) else {
            return nil
        }
        if object.contains("secret") || object.contains("otpType") || (object.contains("issuer") && object.contains("accountName")) {
            return .totp
        }
        if object.contains("cardNumber") || object.contains("cardholderName") || object.contains("cvv") || (object.contains("number") && object.contains("expMonth")) {
            return .card
        }
        if object.contains("documentNumber") || object.contains("documentType") || object.contains("passportNumber") || object.contains("licenseNumber") || object.contains("issuedBy") || object.contains("issuingAuthority") {
            return .identity
        }
        if object.contains("content") || object.contains("markdown") || object.contains("tags") {
            return .note
        }
        return nil
    }

    private static func parseLegacySecureItem(
        kind: BackupKind,
        title: String,
        itemData: String,
        notes: String
    ) -> VaultCSVItemDraft? {
        switch kind {
        case .totp:
            let object = (try? JSONObject(jsonString: itemData)) ?? JSONObject.empty()
            return .totp(LocalTotpEntryDraft(
                title: title,
                secret: object.string("secret"),
                issuer: object.string("issuer"),
                accountName: object.string("accountName"),
                period: UInt32(object.int("period", defaultValue: 30)),
                digits: UInt32(object.int("digits", defaultValue: 6)),
                algorithm: object.string("algorithm", defaultValue: "SHA1"),
                otpType: object.string("otpType", defaultValue: "TOTP"),
                counter: UInt64(object.int("counter", defaultValue: 0))
            ))
        case .note:
            return .note(LocalNoteEntryDraft(title: title, body: itemData.isEmpty ? notes : itemData))
        case .card:
            let object = (try? JSONObject(jsonString: itemData)) ?? JSONObject.empty()
            return .card(LocalCardEntryDraft(
                title: title,
                cardholderName: object.string("cardholderName"),
                number: object.string("cardNumber", defaultValue: object.string("number")),
                expiryMonth: object.string("expiryMonth", defaultValue: object.string("expMonth")),
                expiryYear: object.string("expiryYear", defaultValue: object.string("expYear")),
                cvv: object.string("cvv", defaultValue: object.string("code")),
                issuer: object.string("bankName"),
                network: object.string("brand"),
                notes: notes
            ))
        case .identity:
            let object = (try? JSONObject(jsonString: itemData)) ?? JSONObject.empty()
            return .identity(LocalIdentityEntryDraft(
                title: title,
                documentType: object.string("documentType"),
                fullName: object.string("fullName"),
                documentNumber: object.string("documentNumber", defaultValue: object.string("passportNumber", defaultValue: object.string("licenseNumber"))),
                issuer: object.string("issuedBy", defaultValue: object.string("issuingAuthority")),
                country: object.string("country", defaultValue: object.string("nationality")),
                issueDate: object.string("issuedDate", defaultValue: object.string("issueDate")),
                expiryDate: object.string("expiryDate"),
                notes: notes
            ))
        case .password, .passkey:
            return nil
        }
    }

    private static func parseItem(
        kind: BackupKind,
        data: Data,
        path: String,
        issues: inout [AndroidBackupImportIssue]
    ) -> AndroidBackupImportedItem? {
        do {
            let object = try JSONObject(data: data)
            let sourceID = object.contains("id") ? Int64(object.int("id", defaultValue: 0)) : nil
            let draft: VaultCSVItemDraft
            switch kind {
            case .password:
                draft = .login(LocalLoginEntryDraft(
                    title: object.string("title"),
                    username: object.string("username"),
                    password: object.string("password"),
                    url: object.string("website"),
                    notes: object.string("notes")
                ))
            case .totp:
                let itemData = try object.nestedObject("itemData")
                draft = .totp(LocalTotpEntryDraft(
                    title: object.string("title"),
                    secret: itemData.string("secret"),
                    issuer: itemData.string("issuer"),
                    accountName: itemData.string("accountName"),
                    period: UInt32(itemData.int("period", defaultValue: 30)),
                    digits: UInt32(itemData.int("digits", defaultValue: 6)),
                    algorithm: itemData.string("algorithm", defaultValue: "SHA1"),
                    otpType: itemData.string("otpType", defaultValue: "TOTP"),
                    counter: UInt64(itemData.int("counter", defaultValue: 0))
                ))
            case .note:
                draft = .note(LocalNoteEntryDraft(
                    title: object.string("title"),
                    body: object.string("itemData", defaultValue: object.string("notes"))
                ))
            case .card:
                let itemData = try object.nestedObject("itemData")
                draft = .card(LocalCardEntryDraft(
                    title: object.string("title"),
                    cardholderName: itemData.string("cardholderName"),
                    number: itemData.string("cardNumber", defaultValue: itemData.string("number")),
                    expiryMonth: itemData.string("expiryMonth", defaultValue: itemData.string("expMonth")),
                    expiryYear: itemData.string("expiryYear", defaultValue: itemData.string("expYear")),
                    cvv: itemData.string("cvv", defaultValue: itemData.string("code")),
                    issuer: itemData.string("bankName", defaultValue: object.string("issuer")),
                    network: itemData.string("brand"),
                    notes: object.string("notes")
                ))
            case .identity:
                let itemData = try object.nestedObject("itemData")
                draft = .identity(LocalIdentityEntryDraft(
                    title: object.string("title"),
                    documentType: itemData.string("documentType"),
                    fullName: itemData.string("fullName"),
                    documentNumber: itemData.string("documentNumber", defaultValue: itemData.string("passportNumber", defaultValue: itemData.string("licenseNumber"))),
                    issuer: itemData.string("issuedBy", defaultValue: itemData.string("issuingAuthority")),
                    country: itemData.string("country", defaultValue: itemData.string("nationality")),
                    issueDate: itemData.string("issuedDate", defaultValue: itemData.string("issueDate")),
                    expiryDate: itemData.string("expiryDate"),
                    notes: object.string("notes")
                ))
            case .passkey:
                draft = .passkey(LocalPasskeyEntryDraft(
                    title: object.string("rpName", defaultValue: object.string("rpId")),
                    relyingPartyID: object.string("rpId"),
                    username: object.string("userName", defaultValue: object.string("userDisplayName")),
                    userHandle: object.string("userId"),
                    credentialID: object.string("credentialId"),
                    publicKeyCOSE: object.string("publicKey"),
                    privateKeyReference: object.string("privateKeyAlias"),
                    notes: object.string("notes")
                ))
            }
            return AndroidBackupImportedItem(sourceID: sourceID, draft: draft)
        } catch {
            issues.append(issue(entryPath: path, code: .malformedJSON, detail: "Android 备份 JSON 无法解析"))
            return nil
        }
    }

    private static func entryPath(for item: VaultCSVItemDraft, folderName: String, id: Int, timestamp: Int) -> String {
        let folder = safeFolderName(folderName)
        switch item {
        case .login:
            return "folders/\(folder)/passwords/password_\(id)_\(timestamp).json"
        case .totp:
            return "folders/\(folder)/authenticators/totp_\(id)_\(timestamp).json"
        case .note:
            return "folders/\(folder)/notes/note_\(id)_\(timestamp).json"
        case .card:
            return "folders/\(folder)/bank_cards/bank_card_\(id)_\(timestamp).json"
        case .identity:
            return "folders/\(folder)/documents/document_\(id)_\(timestamp).json"
        case .passkey(let draft):
            return "folders/\(folder)/passkeys/passkey_\(safeFileComponent(draft.credentialID.isEmpty ? String(id) : draft.credentialID)).json"
        case .sshKey:
            return "folders/\(folder)/passwords/password_\(id)_\(timestamp).json"
        case .apiToken:
            return "folders/\(folder)/passwords/password_\(id)_\(timestamp).json"
        case .wifi:
            return "folders/\(folder)/passwords/password_\(id)_\(timestamp).json"
        case .send:
            return "folders/\(folder)/notes/note_\(id)_\(timestamp).json"
        }
    }

    private static func jsonString(for item: VaultCSVItemDraft, id: Int, timestamp: Int, folderName: String) throws -> String {
        let object: [String: Any]
        switch item {
        case .login(let draft):
            object = passwordObject(id: id, timestamp: timestamp, folderName: folderName, title: draft.title, username: draft.username, password: draft.password, website: draft.url)
        case .totp(let draft):
            object = [
                "id": id,
                "title": draft.title,
                "itemData": jsonStringObject([
                    "secret": draft.secret,
                    "issuer": draft.issuer,
                    "accountName": draft.accountName,
                    "period": Int(draft.period),
                    "digits": Int(draft.digits),
                    "algorithm": draft.algorithm,
                    "otpType": draft.otpType,
                    "counter": Int(draft.counter)
                ]),
                "notes": "",
                "isFavorite": false,
                "createdAt": timestamp,
                "updatedAt": timestamp,
                "categoryName": folderName
            ]
        case .note(let draft):
            object = secureItemObject(id: id, timestamp: timestamp, folderName: folderName, itemType: "NOTE", title: draft.title, itemData: draft.body, notes: "")
        case .card(let draft):
            object = secureItemObject(
                id: id,
                timestamp: timestamp,
                folderName: folderName,
                itemType: "BANK_CARD",
                title: draft.title,
                itemData: jsonStringObject([
                    "cardNumber": draft.number,
                    "cardholderName": draft.cardholderName,
                    "expiryMonth": draft.expiryMonth,
                    "expiryYear": draft.expiryYear,
                    "cvv": draft.cvv,
                    "bankName": draft.issuer,
                    "brand": draft.network
                ]),
                notes: draft.notes
            )
        case .identity(let draft):
            object = secureItemObject(
                id: id,
                timestamp: timestamp,
                folderName: folderName,
                itemType: "DOCUMENT",
                title: draft.title,
                itemData: jsonStringObject([
                    "documentType": draft.documentType,
                    "documentNumber": draft.documentNumber,
                    "fullName": draft.fullName,
                    "issuedDate": draft.issueDate,
                    "expiryDate": draft.expiryDate,
                    "issuedBy": draft.issuer,
                    "country": draft.country
                ]),
                notes: draft.notes
            )
        case .passkey(let draft):
            object = [
                "credentialId": draft.credentialID,
                "rpId": draft.relyingPartyID,
                "rpName": draft.title,
                "userId": draft.userHandle,
                "userName": draft.username,
                "userDisplayName": draft.username,
                "publicKeyAlgorithm": -7,
                "publicKey": draft.publicKeyCOSE,
                "privateKeyAlias": draft.privateKeyReference,
                "createdAt": timestamp,
                "lastUsedAt": timestamp,
                "useCount": 0,
                "isDiscoverable": true,
                "isUserVerificationRequired": true,
                "transports": "internal",
                "aaguid": "",
                "signCount": 0,
                "notes": draft.notes,
                "passkeyMode": "LEGACY",
                "categoryName": folderName
            ]
        case .sshKey(let draft):
            object = passwordObject(id: id, timestamp: timestamp, folderName: folderName, title: draft.title, username: draft.username, password: draft.privateKeyReference, website: draft.host, notes: draft.notes, sshKeyData: draft.publicKey)
        case .apiToken(let draft):
            object = passwordObject(id: id, timestamp: timestamp, folderName: folderName, title: draft.title, username: draft.accountName, password: draft.token, website: draft.issuer, notes: draft.notes, loginType: "API_TOKEN")
        case .wifi(let draft):
            object = passwordObject(id: id, timestamp: timestamp, folderName: folderName, title: draft.title, username: draft.ssid, password: draft.password, website: "", notes: draft.notes, loginType: "WIFI", wifiMetadata: jsonStringObject(["ssid": draft.ssid, "securityType": draft.securityType, "hidden": draft.hidden]))
        case .send(let draft):
            object = secureItemObject(id: id, timestamp: timestamp, folderName: folderName, itemType: "NOTE", title: draft.title, itemData: draft.body, notes: draft.notes)
        }
        return jsonStringObject(object)
    }

    private static func passwordObject(
        id: Int,
        timestamp: Int,
        folderName: String,
        title: String,
        username: String,
        password: String,
        website: String,
        notes: String = "",
        loginType: String = "PASSWORD",
        sshKeyData: String = "",
        wifiMetadata: String = ""
    ) -> [String: Any] {
        [
            "id": id,
            "title": title,
            "username": username,
            "password": password,
            "website": website,
            "notes": notes,
            "isFavorite": false,
            "categoryName": folderName,
            "createdAt": timestamp,
            "updatedAt": timestamp,
            "authenticatorKey": "",
            "passkeyBindings": "",
            "sshKeyData": sshKeyData,
            "loginType": loginType,
            "wifiMetadata": wifiMetadata,
            "customFields": []
        ]
    }

    private static func secureItemObject(
        id: Int,
        timestamp: Int,
        folderName: String,
        itemType: String,
        title: String,
        itemData: String,
        notes: String
    ) -> [String: Any] {
        [
            "id": id,
            "itemType": itemType,
            "title": title,
            "itemData": itemData,
            "notes": notes,
            "isFavorite": false,
            "imagePaths": "",
            "createdAt": timestamp,
            "updatedAt": timestamp,
            "categoryName": folderName
        ]
    }

    private static func jsonStringObject(_ object: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func parseCSVRows(_ csv: String) throws -> [[String]] {
        let input = csv.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return [] }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]
            if isQuoted {
                if character == "\"" {
                    let next = input.index(after: index)
                    if next < input.endIndex, input[next] == "\"" {
                        field.append("\"")
                        index = input.index(after: next)
                    } else {
                        isQuoted = false
                        index = next
                    }
                } else {
                    field.append(character)
                    index = input.index(after: index)
                }
            } else {
                switch character {
                case "\"":
                    isQuoted = true
                    index = input.index(after: index)
                case ",":
                    row.append(normalizedCSVField(field))
                    field = ""
                    index = input.index(after: index)
                case "\n":
                    row.append(normalizedCSVField(field))
                    rows.append(row)
                    row = []
                    field = ""
                    index = input.index(after: index)
                case "\r":
                    index = input.index(after: index)
                default:
                    field.append(character)
                    index = input.index(after: index)
                }
            }
        }
        if isQuoted {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        row.append(normalizedCSVField(field))
        rows.append(row)
        return rows
    }

    private static func normalizedCSVField(_ field: String) -> String {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("\u{FEFF}") ? String(trimmed.dropFirst()) : trimmed
    }

    private static func normalizedCSVHeader(_ field: String) -> String {
        normalizedCSVField(field).lowercased()
    }

    private static func csvValue(_ field: String, row: [String], headerIndex: [String: Int], fallback: String = "") -> String {
        guard let index = headerIndex[field], index < row.count else {
            return fallback
        }
        let value = row[index]
        return value.isEmpty ? fallback : value
    }

    private static func normalizedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
    }

    private static func isSafeEntryPath(_ path: String) -> Bool {
        !path.split(separator: "/").contains("..") && !path.hasPrefix("/")
    }

    private static func safeFolderName(_ value: String) -> String {
        safeFileComponent(value.isEmpty ? "Imported" : value)
    }

    private static func safeFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ."))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private static func issue(entryPath: String, code: AndroidBackupIssueCode, detail: String) -> AndroidBackupImportIssue {
        AndroidBackupImportIssue(entryPath: entryPath, code: code, message: "\(entryPath)：\(detail)")
    }
}

private struct JSONObject {
    private let values: [String: Any]
    static func empty() -> JSONObject {
        JSONObject(values: [:])
    }

    init(data: Data) throws {
        let decoded = try JSONSerialization.jsonObject(with: data)
        guard let values = decoded as? [String: Any] else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        self.values = values
    }

    init(jsonString: String) throws {
        try self.init(data: Data(jsonString.utf8))
    }

    func string(_ key: String, defaultValue: String = "") -> String {
        switch values[key] {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return defaultValue
        }
    }

    func int(_ key: String, defaultValue: Int) -> Int {
        switch values[key] {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value) ?? defaultValue
        default:
            return defaultValue
        }
    }

    func contains(_ key: String) -> Bool {
        values[key] != nil
    }

    func nestedObject(_ key: String) throws -> JSONObject {
        switch values[key] {
        case let value as [String: Any]:
            return JSONObject(values: value)
        case let value as String:
            return try JSONObject(jsonString: value)
        default:
            return JSONObject(values: [:])
        }
    }

    private init(values: [String: Any]) {
        self.values = values
    }
}

public enum VaultCSVCodec {
    public static let columns: [String] = [
        "kind",
        "title",
        "username",
        "password",
        "url",
        "body",
        "secret",
        "issuer",
        "accountName",
        "period",
        "digits",
        "algorithm",
        "otpType",
        "counter",
        "cardholderName",
        "number",
        "expiryMonth",
        "expiryYear",
        "cvv",
        "network",
        "documentType",
        "fullName",
        "documentNumber",
        "country",
        "issueDate",
        "expiryDate",
        "relyingPartyID",
        "userHandle",
        "credentialID",
        "publicKeyCOSE",
        "privateKeyReference",
        "host",
        "publicKey",
        "passphraseHint",
        "token",
        "scopes",
        "expiresAt",
        "ssid",
        "securityType",
        "hidden",
        "maxViews",
        "notes"
    ]

    public static let headerLine = columns.joined(separator: ",")

    public static func importItems(from csv: String) -> VaultCSVImportReport {
        do {
            let rows = try parseRows(csv)
            guard let header = rows.first else {
                return VaultCSVImportReport(
                    items: [],
                    issues: [issue(row: 1, code: .emptyCSV, field: nil, detail: "CSV 文件为空")]
                )
            }
            let headerIndex = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($0.element, $0.offset) })
            guard headerIndex["kind"] != nil else {
                return VaultCSVImportReport(
                    items: [],
                    issues: [issue(row: 1, code: .missingKindColumn, field: "kind", detail: "CSV 缺少 kind 列")]
                )
            }

            var items: [VaultCSVItemDraft] = []
            var issues: [VaultCSVImportIssue] = []
            for (offset, row) in rows.dropFirst().enumerated() {
                let rowNumber = offset + 2
                if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    continue
                }
                var record = CSVRecord(row: row, headerIndex: headerIndex)
                if let item = parseItem(record: &record, rowNumber: rowNumber, issues: &issues) {
                    items.append(item)
                }
            }
            return VaultCSVImportReport(items: items, issues: issues)
        } catch {
            return VaultCSVImportReport(
                items: [],
                issues: [issue(row: 1, code: .malformedCSV, field: nil, detail: "CSV 格式无法解析")]
            )
        }
    }

    public static func exportItems(_ items: [VaultCSVItemDraft]) -> String {
        let rows = [columns] + items.map(row(for:))
        return rows.map { row in row.map(escape).joined(separator: ",") }.joined(separator: "\n")
    }

    private static func parseItem(
        record: inout CSVRecord,
        rowNumber: Int,
        issues: inout [VaultCSVImportIssue]
    ) -> VaultCSVItemDraft? {
        let kindValue = record.value("kind")
        guard let kind = UnifiedVaultItemKind(rawValue: kindValue) else {
            issues.append(issue(row: rowNumber, code: .unsupportedKind, field: "kind", detail: "不支持的条目类型"))
            return nil
        }
        let title = record.value("title")
        guard !title.isEmpty else {
            issues.append(issue(row: rowNumber, code: .missingRequiredField, field: "title", detail: "缺少必填字段 title"))
            return nil
        }

        switch kind {
        case .login:
            return .login(LocalLoginEntryDraft(
                title: title,
                username: record.value("username"),
                password: record.value("password"),
                url: record.value("url"),
                notes: record.value("notes")
            ))
        case .note:
            return .note(LocalNoteEntryDraft(title: title, body: record.value("body")))
        case .totp:
            guard let period = uint32(record.value("period"), defaultValue: 30, row: rowNumber, field: "period", issues: &issues),
                  let digits = uint32(record.value("digits"), defaultValue: 6, row: rowNumber, field: "digits", issues: &issues),
                  let counter = uint64(record.value("counter"), defaultValue: 0, row: rowNumber, field: "counter", issues: &issues)
            else { return nil }
            return .totp(LocalTotpEntryDraft(
                title: title,
                secret: record.value("secret"),
                issuer: record.value("issuer"),
                accountName: record.value("accountName"),
                period: period,
                digits: digits,
                algorithm: record.value("algorithm", fallback: "SHA1"),
                otpType: record.value("otpType", fallback: "totp"),
                counter: counter
            ))
        case .card:
            return .card(LocalCardEntryDraft(
                title: title,
                cardholderName: record.value("cardholderName"),
                number: record.value("number"),
                expiryMonth: record.value("expiryMonth"),
                expiryYear: record.value("expiryYear"),
                cvv: record.value("cvv"),
                issuer: record.value("issuer"),
                network: record.value("network"),
                notes: record.value("notes")
            ))
        case .identity:
            return .identity(LocalIdentityEntryDraft(
                title: title,
                documentType: record.value("documentType"),
                fullName: record.value("fullName"),
                documentNumber: record.value("documentNumber"),
                issuer: record.value("issuer"),
                country: record.value("country"),
                issueDate: record.value("issueDate"),
                expiryDate: record.value("expiryDate"),
                notes: record.value("notes")
            ))
        case .passkey:
            return .passkey(LocalPasskeyEntryDraft(
                title: title,
                relyingPartyID: record.value("relyingPartyID"),
                username: record.value("username"),
                userHandle: record.value("userHandle"),
                credentialID: record.value("credentialID"),
                publicKeyCOSE: record.value("publicKeyCOSE"),
                privateKeyReference: record.value("privateKeyReference"),
                notes: record.value("notes")
            ))
        case .sshKey:
            return .sshKey(LocalSshKeyEntryDraft(
                title: title,
                username: record.value("username"),
                host: record.value("host"),
                publicKey: record.value("publicKey"),
                privateKeyReference: record.value("privateKeyReference"),
                passphraseHint: record.value("passphraseHint"),
                notes: record.value("notes")
            ))
        case .apiToken:
            return .apiToken(LocalApiTokenEntryDraft(
                title: title,
                issuer: record.value("issuer"),
                accountName: record.value("accountName"),
                token: record.value("token"),
                scopes: record.value("scopes"),
                expiresAt: record.value("expiresAt"),
                notes: record.value("notes")
            ))
        case .wifi:
            guard let hidden = bool(record.value("hidden"), defaultValue: false, row: rowNumber, field: "hidden", issues: &issues) else {
                return nil
            }
            return .wifi(LocalWifiEntryDraft(
                title: title,
                ssid: record.value("ssid"),
                securityType: record.value("securityType"),
                password: record.value("password"),
                hidden: hidden,
                notes: record.value("notes")
            ))
        case .send:
            guard let maxViews = int(record.value("maxViews"), defaultValue: 1, row: rowNumber, field: "maxViews", issues: &issues) else {
                return nil
            }
            return .send(LocalSendEntryDraft(
                title: title,
                body: record.value("body"),
                expiresAt: record.value("expiresAt"),
                maxViews: maxViews,
                notes: record.value("notes")
            ))
        case .attachmentRef:
            issues.append(issue(row: rowNumber, code: .unsupportedKind, field: "kind", detail: "CSV 暂不导入附件内容"))
            return nil
        }
    }

    private static func row(for item: VaultCSVItemDraft) -> [String] {
        var values = Dictionary(uniqueKeysWithValues: columns.map { ($0, "") })
        values["kind"] = item.kind.rawValue
        switch item {
        case .login(let draft):
            values["title"] = draft.title
            values["username"] = draft.username
            values["password"] = draft.password
            values["url"] = draft.url
        case .note(let draft):
            values["title"] = draft.title
            values["body"] = draft.body
        case .totp(let draft):
            values["title"] = draft.title
            values["secret"] = draft.secret
            values["issuer"] = draft.issuer
            values["accountName"] = draft.accountName
            values["period"] = String(draft.period)
            values["digits"] = String(draft.digits)
            values["algorithm"] = draft.algorithm
            values["otpType"] = draft.otpType
            values["counter"] = String(draft.counter)
        case .card(let draft):
            values["title"] = draft.title
            values["cardholderName"] = draft.cardholderName
            values["number"] = draft.number
            values["expiryMonth"] = draft.expiryMonth
            values["expiryYear"] = draft.expiryYear
            values["cvv"] = draft.cvv
            values["issuer"] = draft.issuer
            values["network"] = draft.network
            values["notes"] = draft.notes
        case .identity(let draft):
            values["title"] = draft.title
            values["documentType"] = draft.documentType
            values["fullName"] = draft.fullName
            values["documentNumber"] = draft.documentNumber
            values["issuer"] = draft.issuer
            values["country"] = draft.country
            values["issueDate"] = draft.issueDate
            values["expiryDate"] = draft.expiryDate
            values["notes"] = draft.notes
        case .passkey(let draft):
            values["title"] = draft.title
            values["username"] = draft.username
            values["relyingPartyID"] = draft.relyingPartyID
            values["userHandle"] = draft.userHandle
            values["credentialID"] = draft.credentialID
            values["publicKeyCOSE"] = draft.publicKeyCOSE
            values["privateKeyReference"] = draft.privateKeyReference
            values["notes"] = draft.notes
        case .sshKey(let draft):
            values["title"] = draft.title
            values["username"] = draft.username
            values["host"] = draft.host
            values["publicKey"] = draft.publicKey
            values["privateKeyReference"] = draft.privateKeyReference
            values["passphraseHint"] = draft.passphraseHint
            values["notes"] = draft.notes
        case .apiToken(let draft):
            values["title"] = draft.title
            values["issuer"] = draft.issuer
            values["accountName"] = draft.accountName
            values["token"] = draft.token
            values["scopes"] = draft.scopes
            values["expiresAt"] = draft.expiresAt
            values["notes"] = draft.notes
        case .wifi(let draft):
            values["title"] = draft.title
            values["ssid"] = draft.ssid
            values["securityType"] = draft.securityType
            values["password"] = draft.password
            values["hidden"] = String(draft.hidden)
            values["notes"] = draft.notes
        case .send(let draft):
            values["title"] = draft.title
            values["body"] = draft.body
            values["expiresAt"] = draft.expiresAt
            values["maxViews"] = String(draft.maxViews)
            values["notes"] = draft.notes
        }
        return columns.map { values[$0] ?? "" }
    }

    private static func parseRows(_ csv: String) throws -> [[String]] {
        let input = csv.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return [] }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]
            if isQuoted {
                if character == "\"" {
                    let next = input.index(after: index)
                    if next < input.endIndex, input[next] == "\"" {
                        field.append("\"")
                        index = input.index(after: next)
                    } else {
                        isQuoted = false
                        index = next
                    }
                } else {
                    field.append(character)
                    index = input.index(after: index)
                }
            } else {
                switch character {
                case "\"":
                    isQuoted = true
                    index = input.index(after: index)
                case ",":
                    row.append(normalizedField(field))
                    field = ""
                    index = input.index(after: index)
                case "\n":
                    row.append(normalizedField(field))
                    rows.append(row)
                    row = []
                    field = ""
                    index = input.index(after: index)
                case "\r":
                    index = input.index(after: index)
                default:
                    field.append(character)
                    index = input.index(after: index)
                }
            }
        }
        if isQuoted { throw LocalVaultRepositoryError.vaultUnavailable }
        row.append(normalizedField(field))
        rows.append(row)
        return rows
    }

    private static func normalizedField(_ field: String) -> String {
        field.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\n") || value.contains("\"") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private static func uint32(
        _ value: String,
        defaultValue: UInt32,
        row: Int,
        field: String,
        issues: inout [VaultCSVImportIssue]
    ) -> UInt32? {
        guard !value.isEmpty else { return defaultValue }
        guard let parsed = UInt32(value) else {
            issues.append(issue(row: row, code: .invalidNumber, field: field, detail: "数字字段格式错误"))
            return nil
        }
        return parsed
    }

    private static func uint64(
        _ value: String,
        defaultValue: UInt64,
        row: Int,
        field: String,
        issues: inout [VaultCSVImportIssue]
    ) -> UInt64? {
        guard !value.isEmpty else { return defaultValue }
        guard let parsed = UInt64(value) else {
            issues.append(issue(row: row, code: .invalidNumber, field: field, detail: "数字字段格式错误"))
            return nil
        }
        return parsed
    }

    private static func int(
        _ value: String,
        defaultValue: Int,
        row: Int,
        field: String,
        issues: inout [VaultCSVImportIssue]
    ) -> Int? {
        guard !value.isEmpty else { return defaultValue }
        guard let parsed = Int(value) else {
            issues.append(issue(row: row, code: .invalidNumber, field: field, detail: "数字字段格式错误"))
            return nil
        }
        return parsed
    }

    private static func bool(
        _ value: String,
        defaultValue: Bool,
        row: Int,
        field: String,
        issues: inout [VaultCSVImportIssue]
    ) -> Bool? {
        guard !value.isEmpty else { return defaultValue }
        switch value.lowercased() {
        case "true", "1", "yes", "y": return true
        case "false", "0", "no", "n": return false
        default:
            issues.append(issue(row: row, code: .invalidBoolean, field: field, detail: "布尔字段格式错误"))
            return nil
        }
    }

    private static func issue(row: Int, code: VaultCSVImportIssueCode, field: String?, detail: String) -> VaultCSVImportIssue {
        let fieldText = field.map { " 字段 \($0)" } ?? ""
        return VaultCSVImportIssue(row: row, code: code, field: field, message: "第 \(row) 行\(fieldText)：\(detail)")
    }
}

private struct CSVRecord {
    let row: [String]
    let headerIndex: [String: Int]

    func value(_ field: String, fallback: String = "") -> String {
        guard let index = headerIndex[field], index < row.count else {
            return fallback
        }
        let value = row[index]
        return value.isEmpty ? fallback : value
    }
}

public protocol ItemRepository {
    func listItems(
        source: VaultSource?,
        kinds: [UnifiedVaultItemKind],
        includeDeleted: Bool
    ) throws -> [UnifiedVaultItem]

    func deleteItem(_ item: UnifiedVaultItem) throws
    func restoreItem(_ item: UnifiedVaultItem) throws
    func setFavorite(_ favorite: Bool, for item: UnifiedVaultItem) throws -> UnifiedVaultItem
}

public enum ParityFeatureFlag: String, Sendable, Equatable, CaseIterable {
    case passwords
    case totp
    case notes
    case wallet
    case identities
    case autofill
    case backup
    case keepass
    case bitwarden
    case passkeys
    case attachments
    case settings

    public static let phaseOneEnabled: [ParityFeatureFlag] = [
        .passwords,
        .totp,
        .notes,
        .wallet,
        .identities,
        .settings
    ]

    public static let phaseTwoEnabled: [ParityFeatureFlag] = phaseOneEnabled + [
        .autofill
    ]

    public var isEnabledInPhaseOne: Bool {
        Self.phaseOneEnabled.contains(self)
    }

    public var isEnabledInPhaseTwo: Bool {
        Self.phaseTwoEnabled.contains(self)
    }

    public var disabledReason: String? {
        guard !isEnabledInPhaseTwo else {
            return nil
        }
        switch self {
        case .backup:
            return "第三阶段接入 Android 备份兼容。"
        case .keepass:
            return "第四阶段接入 KDBX 兼容。"
        case .bitwarden:
            return "后续阶段接入 Bitwarden 多真源。"
        case .passkeys:
            return "后续阶段接入 iOS AuthenticationServices。"
        case .attachments:
            return "后续阶段接入附件。"
        case .passwords, .totp, .notes, .wallet, .identities, .autofill, .settings:
            return nil
        }
    }
}

public enum LocalVaultState: Sendable, Equatable {
    case unlocked
    case locked
}

public enum LocalVaultRepositoryError: Error, Sendable, Equatable, LocalizedError {
    case emptyVaultName
    case emptyPassword
    case emptySecurityKeyMaterial
    case emptyProjectTitle
    case emptyEntryTitle
    case vaultUnavailable
    case projectNotFound
    case projectNotEmpty
    case unsupportedEntryType(UnifiedVaultItemKind)
    case invalidEntryPayload

    public var errorDescription: String? {
        switch self {
        case .emptyVaultName:
            return "保险库名称不能为空。"
        case .emptyPassword:
            return "保险库密码不能为空。"
        case .emptySecurityKeyMaterial:
            return "保险库安全密钥材料不能为空。"
        case .emptyProjectTitle:
            return "项目标题不能为空。"
        case .emptyEntryTitle:
            return "条目标题不能为空。"
        case .vaultUnavailable:
            return "保险库会话已不可用。"
        case .projectNotFound:
            return "分类不存在。"
        case .projectNotEmpty:
            return "分类内仍有条目，无法直接删除。"
        case .unsupportedEntryType(let kind):
            return "\(kind.displayName) 还没有接入当前 MDBX 引擎。"
        case .invalidEntryPayload:
            return "保险库条目 payload 无法解析。"
        }
    }
}

public struct LocalVaultDescriptor: Sendable, Equatable {
    public let fileURL: URL
    public let displayName: String

    public init(fileURL: URL, displayName: String) {
        self.fileURL = fileURL
        self.displayName = displayName
    }
}

public struct LocalVaultHandle: Sendable, Equatable {
    public let vaultID: String
    public let deviceID: String

    public init(vaultID: String, deviceID: String) {
        self.vaultID = vaultID
        self.deviceID = deviceID
    }
}

public struct LocalVaultSession: Sendable, Equatable {
    public let descriptor: LocalVaultDescriptor
    public let handle: LocalVaultHandle
    public let state: LocalVaultState

    public init(
        descriptor: LocalVaultDescriptor,
        handle: LocalVaultHandle,
        state: LocalVaultState
    ) {
        self.descriptor = descriptor
        self.handle = handle
        self.state = state
    }
}

public protocol LocalVaultEngine {
    func createVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle

    func openVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle

    func openVaultWithSecurityKey(
        at fileURL: URL,
        securityKeyMaterial: Data,
        deviceID: String
    ) throws -> LocalVaultHandle

    func setupLocalSecurityKeyUnlock(
        in handle: LocalVaultHandle,
        securityKeyMaterial: Data
    ) throws

    func resetMasterPassword(
        in handle: LocalVaultHandle,
        newPassword: String
    ) throws

    func closeVault(_ handle: LocalVaultHandle)

    func createProject(
        in handle: LocalVaultHandle,
        title: String
    ) throws -> LocalVaultProject

    func listProjects(
        in handle: LocalVaultHandle
    ) throws -> [LocalVaultProject]

    func renameProject(
        in handle: LocalVaultHandle,
        projectID: String,
        title: String
    ) throws -> LocalVaultProject

    func deleteProject(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws

    func createLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry

    func listLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry]

    func updateLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry

    func setLoginEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalLoginEntry

    func deleteLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry]

    func restoreLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalLoginEntry

    func createNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry

    func listNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry]

    func updateNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry

    func setNoteEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalNoteEntry

    func deleteNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry]

    func restoreNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalNoteEntry

    func createTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry

    func listTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry]

    func updateTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry

    func setTotpEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalTotpEntry

    func deleteTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry]

    func restoreTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalTotpEntry

    func createCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry

    func listCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry]

    func updateCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry

    func setCardEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalCardEntry

    func deleteCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry]

    func restoreCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalCardEntry

    func createIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry

    func listIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry]

    func updateIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry

    func setIdentityEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalIdentityEntry

    func deleteIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry]

    func restoreIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalIdentityEntry

    func createPasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalPasskeyEntryDraft
    ) throws -> LocalPasskeyEntry

    func listPasskeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalPasskeyEntry]

    func updatePasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalPasskeyEntryDraft
    ) throws -> LocalPasskeyEntry

    func setPasskeyEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalPasskeyEntry

    func deletePasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedPasskeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalPasskeyEntry]

    func restorePasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalPasskeyEntry

    func createSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalSshKeyEntryDraft
    ) throws -> LocalSshKeyEntry

    func listSshKeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSshKeyEntry]

    func updateSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalSshKeyEntryDraft
    ) throws -> LocalSshKeyEntry

    func setSshKeyEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalSshKeyEntry

    func deleteSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedSshKeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSshKeyEntry]

    func restoreSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalSshKeyEntry

    func createApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalApiTokenEntryDraft
    ) throws -> LocalApiTokenEntry

    func listApiTokenEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalApiTokenEntry]

    func updateApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalApiTokenEntryDraft
    ) throws -> LocalApiTokenEntry

    func setApiTokenEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalApiTokenEntry

    func deleteApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedApiTokenEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalApiTokenEntry]

    func restoreApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalApiTokenEntry

    func createWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalWifiEntryDraft
    ) throws -> LocalWifiEntry

    func listWifiEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalWifiEntry]

    func updateWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalWifiEntryDraft
    ) throws -> LocalWifiEntry

    func setWifiEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalWifiEntry

    func deleteWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedWifiEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalWifiEntry]

    func restoreWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalWifiEntry

    func createSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalSendEntryDraft
    ) throws -> LocalSendEntry

    func listSendEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSendEntry]

    func updateSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalSendEntryDraft
    ) throws -> LocalSendEntry

    func setSendEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalSendEntry

    func deleteSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedSendEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSendEntry]

    func restoreSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalSendEntry

    func createAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String,
        downloadState: String,
        wrappedContentEncryptionKey: String?,
        localPath: String?
    ) throws -> LocalAttachmentMetadata

    func listAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalAttachmentMetadata]

    func updateAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String,
        downloadState: String,
        wrappedContentEncryptionKey: String?,
        localPath: String?
    ) throws -> LocalAttachmentMetadata

    func deleteAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String
    ) throws

    func listDeletedAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalAttachmentMetadata]

    func restoreAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String
    ) throws -> LocalAttachmentMetadata

    func moveEntry(
        in handle: LocalVaultHandle,
        kind: UnifiedVaultItemKind,
        entryID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws -> LocalVaultMovedEntry
}

public extension LocalVaultEngine {
    func moveEntry(in handle: LocalVaultHandle, kind: UnifiedVaultItemKind, entryID: String, fromProjectID: String, toProjectID: String) throws -> LocalVaultMovedEntry { throw LocalVaultRepositoryError.unsupportedEntryType(kind) }

    func createPasskeyEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func listPasskeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPasskeyEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func updatePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func setPasskeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalPasskeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func deletePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func listDeletedPasskeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPasskeyEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func restorePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalPasskeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }

    func createSshKeyEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func listSshKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSshKeyEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func updateSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func setSshKeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSshKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func deleteSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func listDeletedSshKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSshKeyEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func restoreSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSshKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }

    func createApiTokenEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func listApiTokenEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalApiTokenEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func updateApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func setApiTokenEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalApiTokenEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func deleteApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func listDeletedApiTokenEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalApiTokenEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func restoreApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalApiTokenEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }

    func createWifiEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func listWifiEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalWifiEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func updateWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func setWifiEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalWifiEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func deleteWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func listDeletedWifiEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalWifiEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func restoreWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalWifiEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }

    func createSendEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func listSendEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSendEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func updateSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func setSendEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSendEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func deleteSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func listDeletedSendEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSendEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func restoreSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSendEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }

    func createAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, entryID: String?, fileName: String, mediaType: String, originalSize: Int64, storedSize: Int64, contentHash: String, storageMode: String, source: String = "", downloadState: String = "", wrappedContentEncryptionKey: String? = nil, localPath: String? = nil) throws -> LocalAttachmentMetadata { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
    func listAttachmentMetadata(in handle: LocalVaultHandle, projectID: String) throws -> [LocalAttachmentMetadata] { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
    func updateAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String, entryID: String?, fileName: String, mediaType: String, originalSize: Int64, storedSize: Int64, contentHash: String, storageMode: String, source: String = "", downloadState: String = "", wrappedContentEncryptionKey: String? = nil, localPath: String? = nil) throws -> LocalAttachmentMetadata { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
    func deleteAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
    func listDeletedAttachmentMetadata(in handle: LocalVaultHandle, projectID: String) throws -> [LocalAttachmentMetadata] { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
    func restoreAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String) throws -> LocalAttachmentMetadata { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
}

public struct LocalVaultProject: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct LocalVaultMovedEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let kind: UnifiedVaultItemKind

    public init(id: String, title: String, kind: UnifiedVaultItemKind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

public struct LocalLoginEntryDraft: Sendable, Equatable {
    public let title: String
    public let username: String
    public let password: String
    public let url: String
    public let notes: String

    public init(
        title: String,
        username: String,
        password: String,
        url: String,
        notes: String = ""
    ) {
        self.title = title
        self.username = username
        self.password = password
        self.url = url
        self.notes = notes
    }
}

public struct LocalLoginEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let username: String
    public let password: String
    public let url: String
    public let notes: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        username: String,
        password: String,
        url: String,
        notes: String = "",
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.username = username
        self.password = password
        self.url = url
        self.notes = notes
        self.favorite = favorite
    }
}

public struct LocalNoteEntryDraft: Sendable, Equatable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public struct LocalNoteEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let body: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        body: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.body = body
        self.favorite = favorite
    }
}

public struct LocalTotpEntryDraft: Sendable, Equatable {
    public let title: String
    public let secret: String
    public let issuer: String
    public let accountName: String
    public let period: UInt32
    public let digits: UInt32
    public let algorithm: String
    public let otpType: String
    public let counter: UInt64

    public init(
        title: String,
        secret: String,
        issuer: String,
        accountName: String,
        period: UInt32,
        digits: UInt32,
        algorithm: String,
        otpType: String,
        counter: UInt64
    ) {
        self.title = title
        self.secret = secret
        self.issuer = issuer
        self.accountName = accountName
        self.period = period
        self.digits = digits
        self.algorithm = algorithm
        self.otpType = otpType
        self.counter = counter
    }
}

public struct LocalTotpEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let secret: String
    public let issuer: String
    public let accountName: String
    public let period: UInt32
    public let digits: UInt32
    public let algorithm: String
    public let otpType: String
    public let counter: UInt64
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        secret: String,
        issuer: String,
        accountName: String,
        period: UInt32,
        digits: UInt32,
        algorithm: String,
        otpType: String,
        counter: UInt64,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.secret = secret
        self.issuer = issuer
        self.accountName = accountName
        self.period = period
        self.digits = digits
        self.algorithm = algorithm
        self.otpType = otpType
        self.counter = counter
        self.favorite = favorite
    }
}

public struct LocalCardEntryDraft: Sendable, Equatable {
    public let title: String
    public let cardholderName: String
    public let number: String
    public let expiryMonth: String
    public let expiryYear: String
    public let cvv: String
    public let issuer: String
    public let network: String
    public let notes: String

    public init(
        title: String,
        cardholderName: String,
        number: String,
        expiryMonth: String,
        expiryYear: String,
        cvv: String,
        issuer: String,
        network: String,
        notes: String
    ) {
        self.title = title
        self.cardholderName = cardholderName
        self.number = number
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear
        self.cvv = cvv
        self.issuer = issuer
        self.network = network
        self.notes = notes
    }
}

public struct LocalCardEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let cardholderName: String
    public let number: String
    public let expiryMonth: String
    public let expiryYear: String
    public let cvv: String
    public let issuer: String
    public let network: String
    public let notes: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        cardholderName: String,
        number: String,
        expiryMonth: String,
        expiryYear: String,
        cvv: String,
        issuer: String,
        network: String,
        notes: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.cardholderName = cardholderName
        self.number = number
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear
        self.cvv = cvv
        self.issuer = issuer
        self.network = network
        self.notes = notes
        self.favorite = favorite
    }
}

public struct LocalIdentityEntryDraft: Sendable, Equatable {
    public let title: String
    public let documentType: String
    public let fullName: String
    public let documentNumber: String
    public let issuer: String
    public let country: String
    public let issueDate: String
    public let expiryDate: String
    public let notes: String

    public init(
        title: String,
        documentType: String,
        fullName: String,
        documentNumber: String,
        issuer: String,
        country: String,
        issueDate: String,
        expiryDate: String,
        notes: String
    ) {
        self.title = title
        self.documentType = documentType
        self.fullName = fullName
        self.documentNumber = documentNumber
        self.issuer = issuer
        self.country = country
        self.issueDate = issueDate
        self.expiryDate = expiryDate
        self.notes = notes
    }
}

public struct LocalIdentityEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let documentType: String
    public let fullName: String
    public let documentNumber: String
    public let issuer: String
    public let country: String
    public let issueDate: String
    public let expiryDate: String
    public let notes: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        documentType: String,
        fullName: String,
        documentNumber: String,
        issuer: String,
        country: String,
        issueDate: String,
        expiryDate: String,
        notes: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.documentType = documentType
        self.fullName = fullName
        self.documentNumber = documentNumber
        self.issuer = issuer
        self.country = country
        self.issueDate = issueDate
        self.expiryDate = expiryDate
        self.notes = notes
        self.favorite = favorite
    }
}

public struct LocalPasskeyEntryDraft: Sendable, Equatable {
    public let title: String
    public let relyingPartyID: String
    public let username: String
    public let userHandle: String
    public let credentialID: String
    public let publicKeyCOSE: String
    public let privateKeyReference: String
    public let notes: String

    public init(
        title: String,
        relyingPartyID: String,
        username: String,
        userHandle: String,
        credentialID: String,
        publicKeyCOSE: String,
        privateKeyReference: String,
        notes: String
    ) {
        self.title = title
        self.relyingPartyID = relyingPartyID
        self.username = username
        self.userHandle = userHandle
        self.credentialID = credentialID
        self.publicKeyCOSE = publicKeyCOSE
        self.privateKeyReference = privateKeyReference
        self.notes = notes
    }
}

public struct LocalPasskeyEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let relyingPartyID: String
    public let username: String
    public let userHandle: String
    public let credentialID: String
    public let publicKeyCOSE: String
    public let privateKeyReference: String
    public let notes: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        relyingPartyID: String,
        username: String,
        userHandle: String,
        credentialID: String,
        publicKeyCOSE: String,
        privateKeyReference: String,
        notes: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.relyingPartyID = relyingPartyID
        self.username = username
        self.userHandle = userHandle
        self.credentialID = credentialID
        self.publicKeyCOSE = publicKeyCOSE
        self.privateKeyReference = privateKeyReference
        self.notes = notes
        self.favorite = favorite
    }
}

public struct LocalSshKeyEntryDraft: Sendable, Equatable {
    public let title: String
    public let username: String
    public let host: String
    public let publicKey: String
    public let privateKeyReference: String
    public let passphraseHint: String
    public let notes: String

    public init(
        title: String,
        username: String,
        host: String,
        publicKey: String,
        privateKeyReference: String,
        passphraseHint: String,
        notes: String
    ) {
        self.title = title
        self.username = username
        self.host = host
        self.publicKey = publicKey
        self.privateKeyReference = privateKeyReference
        self.passphraseHint = passphraseHint
        self.notes = notes
    }
}

public struct LocalSshKeyEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let username: String
    public let host: String
    public let publicKey: String
    public let privateKeyReference: String
    public let passphraseHint: String
    public let notes: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        username: String,
        host: String,
        publicKey: String,
        privateKeyReference: String,
        passphraseHint: String,
        notes: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.username = username
        self.host = host
        self.publicKey = publicKey
        self.privateKeyReference = privateKeyReference
        self.passphraseHint = passphraseHint
        self.notes = notes
        self.favorite = favorite
    }
}

public struct LocalApiTokenEntryDraft: Sendable, Equatable {
    public let title: String
    public let issuer: String
    public let accountName: String
    public let token: String
    public let scopes: String
    public let expiresAt: String
    public let notes: String

    public init(
        title: String,
        issuer: String,
        accountName: String,
        token: String,
        scopes: String,
        expiresAt: String,
        notes: String
    ) {
        self.title = title
        self.issuer = issuer
        self.accountName = accountName
        self.token = token
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.notes = notes
    }
}

public struct LocalApiTokenEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let issuer: String
    public let accountName: String
    public let token: String
    public let scopes: String
    public let expiresAt: String
    public let notes: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        issuer: String,
        accountName: String,
        token: String,
        scopes: String,
        expiresAt: String,
        notes: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.issuer = issuer
        self.accountName = accountName
        self.token = token
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.notes = notes
        self.favorite = favorite
    }
}

public struct LocalWifiEntryDraft: Sendable, Equatable {
    public let title: String
    public let ssid: String
    public let securityType: String
    public let password: String
    public let hidden: Bool
    public let notes: String

    public init(
        title: String,
        ssid: String,
        securityType: String,
        password: String,
        hidden: Bool,
        notes: String
    ) {
        self.title = title
        self.ssid = ssid
        self.securityType = securityType
        self.password = password
        self.hidden = hidden
        self.notes = notes
    }
}

public struct LocalWifiEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let ssid: String
    public let securityType: String
    public let password: String
    public let hidden: Bool
    public let notes: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        ssid: String,
        securityType: String,
        password: String,
        hidden: Bool,
        notes: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.ssid = ssid
        self.securityType = securityType
        self.password = password
        self.hidden = hidden
        self.notes = notes
        self.favorite = favorite
    }
}

public extension LocalWifiEntry {
    var qrCodePayload: String {
        let type = normalizedQRCodeSecurityType
        let passwordSegment = type == "nopass" ? "" : "P:\(Self.qrEscaped(password));"
        return "WIFI:T:\(type);S:\(Self.qrEscaped(ssid));\(passwordSegment)H:\(hidden ? "true" : "false");;"
    }

    private var normalizedQRCodeSecurityType: String {
        let normalized = securityType.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalized.isEmpty || normalized == "OPEN" || normalized == "NONE" || normalized == "NOPASS" {
            return "nopass"
        }
        if normalized.contains("WEP") {
            return "WEP"
        }
        return "WPA"
    }

    private static func qrEscaped(_ value: String) -> String {
        value.reduce(into: "") { result, character in
            if "\\;,:\"".contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
    }
}

public struct LocalSendEntryDraft: Sendable, Equatable {
    public let title: String
    public let body: String
    public let expiresAt: String
    public let maxViews: Int
    public let notes: String

    public init(
        title: String,
        body: String,
        expiresAt: String,
        maxViews: Int,
        notes: String
    ) {
        self.title = title
        self.body = body
        self.expiresAt = expiresAt
        self.maxViews = maxViews
        self.notes = notes
    }
}

public struct LocalSendEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let body: String
    public let expiresAt: String
    public let maxViews: Int
    public let notes: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        body: String,
        expiresAt: String,
        maxViews: Int,
        notes: String,
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.body = body
        self.expiresAt = expiresAt
        self.maxViews = maxViews
        self.notes = notes
        self.favorite = favorite
    }
}

public struct LocalAttachmentMetadata: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let entryID: String?
    public let fileName: String
    public let mediaType: String
    public let originalSize: Int64
    public let storedSize: Int64
    public let contentHash: String
    public let storageMode: String
    public let source: String
    public let downloadState: String
    public let wrappedContentEncryptionKey: String?
    public let localPath: String?
    public let deleted: Bool

    public init(
        id: String,
        projectID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String = "",
        downloadState: String = "",
        wrappedContentEncryptionKey: String? = nil,
        localPath: String? = nil,
        deleted: Bool
    ) {
        self.id = id
        self.projectID = projectID
        self.entryID = entryID
        self.fileName = fileName
        self.mediaType = mediaType
        self.originalSize = originalSize
        self.storedSize = storedSize
        self.contentHash = contentHash
        self.storageMode = storageMode
        self.source = source
        self.downloadState = downloadState
        self.wrappedContentEncryptionKey = wrappedContentEncryptionKey
        self.localPath = localPath
        self.deleted = deleted
    }
}

public struct AutoFillEncryptedIndexRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let nonce: Data
    public let ciphertext: Data
    public let authenticationTag: Data

    public init(
        id: String,
        nonce: Data,
        ciphertext: Data,
        authenticationTag: Data
    ) {
        self.id = id
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.authenticationTag = authenticationTag
    }
}

public struct AutoFillCredentialIndexRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let username: String
    public let serviceIdentifiers: [String]

    public init(
        id: String,
        title: String,
        username: String,
        serviceIdentifiers: [String]
    ) {
        self.id = id
        self.title = title
        self.username = username
        self.serviceIdentifiers = serviceIdentifiers
    }
}

public struct AutoFillCredentialSecretRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let username: String
    public let password: String

    public init(id: String, username: String, password: String) {
        self.id = id
        self.username = username
        self.password = password
    }
}

public enum AutoFillEncryptedIndexCodecError: Error, Sendable, Equatable, LocalizedError {
    case invalidKeyLength(expected: Int, actual: Int)
    case vaultIdentifierMismatch(expected: String, actual: String)
    case keyIdentifierMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength(let expected, let actual):
            return "自动填充索引密钥必须是 \(expected) 字节，当前为 \(actual) 字节。"
        case .vaultIdentifierMismatch(let expected, let actual):
            return "自动填充索引保险库不匹配。预期 \(expected)，当前 \(actual)。"
        case .keyIdentifierMismatch(let expected, let actual):
            return "自动填充索引密钥不匹配。预期 \(expected)，当前 \(actual)。"
        }
    }
}

public struct AutoFillIndexEncryptionKey: Sendable, Equatable {
    public static let requiredByteCount = 32

    public let rawValue: Data

    public init(rawValue: Data) throws {
        guard rawValue.count == AutoFillIndexEncryptionKey.requiredByteCount else {
            throw AutoFillEncryptedIndexCodecError.invalidKeyLength(
                expected: AutoFillIndexEncryptionKey.requiredByteCount,
                actual: rawValue.count
            )
        }

        self.rawValue = rawValue
    }
}

public struct AutoFillEncryptedIndexCodec: Sendable {
    public init() {}

    public func encrypt(
        _ records: [AutoFillCredentialIndexRecord],
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        key: AutoFillIndexEncryptionKey
    ) throws -> AutoFillEncryptedIndex {
        let symmetricKey = SymmetricKey(data: key.rawValue)
        let encryptedRecords = try records.map { record in
            let plaintext = try Self.payloadEncoder.encode(record)
            let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey)
            return AutoFillEncryptedIndexRecord(
                id: record.id,
                nonce: Data(sealedBox.nonce),
                ciphertext: sealedBox.ciphertext,
                authenticationTag: sealedBox.tag
            )
        }

        return AutoFillEncryptedIndex(
            vaultID: vaultID,
            keyIdentifier: keyIdentifier,
            updatedAt: updatedAt,
            records: encryptedRecords
        )
    }

    public func decrypt(
        _ index: AutoFillEncryptedIndex,
        key: AutoFillIndexEncryptionKey
    ) throws -> [AutoFillCredentialIndexRecord] {
        let symmetricKey = SymmetricKey(data: key.rawValue)
        return try index.records.map { record in
            let nonce = try AES.GCM.Nonce(data: record.nonce)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: record.ciphertext,
                tag: record.authenticationTag
            )
            let plaintext = try AES.GCM.open(sealedBox, using: symmetricKey)
            return try Self.payloadDecoder.decode(
                AutoFillCredentialIndexRecord.self,
                from: plaintext
            )
        }
    }

    private static let payloadEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let payloadDecoder = JSONDecoder()
}

public struct AutoFillEncryptedIndex: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let vaultID: String
    public let keyIdentifier: String
    public let updatedAt: Date
    public let records: [AutoFillEncryptedIndexRecord]

    public init(
        schemaVersion: Int = AutoFillEncryptedIndex.currentSchemaVersion,
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        records: [AutoFillEncryptedIndexRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.vaultID = vaultID
        self.keyIdentifier = keyIdentifier
        self.updatedAt = updatedAt
        self.records = records
    }
}

public struct AutoFillEncryptedCredentialSecretRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let nonce: Data
    public let ciphertext: Data
    public let authenticationTag: Data

    public init(
        id: String,
        nonce: Data,
        ciphertext: Data,
        authenticationTag: Data
    ) {
        self.id = id
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.authenticationTag = authenticationTag
    }
}

public struct AutoFillCredentialSecretSnapshot: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let vaultID: String
    public let keyIdentifier: String
    public let updatedAt: Date
    public let records: [AutoFillEncryptedCredentialSecretRecord]

    public init(
        schemaVersion: Int = AutoFillCredentialSecretSnapshot.currentSchemaVersion,
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        records: [AutoFillEncryptedCredentialSecretRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.vaultID = vaultID
        self.keyIdentifier = keyIdentifier
        self.updatedAt = updatedAt
        self.records = records
    }
}

public protocol AutoFillEncryptedIndexStore: Sendable {
    func save(_ index: AutoFillEncryptedIndex) throws
    func load() throws -> AutoFillEncryptedIndex?
    func delete() throws
}

public protocol AutoFillCredentialSecretStore: Sendable {
    func save(_ snapshot: AutoFillCredentialSecretSnapshot) throws
    func load() throws -> AutoFillCredentialSecretSnapshot?
    func delete() throws
}

public struct AutoFillUnlockedCredentialIndex: Sendable, Equatable {
    public let vaultID: String
    public let keyIdentifier: String
    public let updatedAt: Date
    public let records: [AutoFillCredentialIndexRecord]

    public init(
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        records: [AutoFillCredentialIndexRecord]
    ) {
        self.vaultID = vaultID
        self.keyIdentifier = keyIdentifier
        self.updatedAt = updatedAt
        self.records = records
    }

    public func search(_ query: String) -> [AutoFillCredentialIndexRecord] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else {
            return records
        }

        return records.filter { record in
            record.title.localizedCaseInsensitiveContains(normalizedQuery)
                || record.username.localizedCaseInsensitiveContains(normalizedQuery)
                || record.serviceIdentifiers.contains {
                    $0.localizedCaseInsensitiveContains(normalizedQuery)
                }
        }
    }

    public func records(
        matchingServiceIdentifier serviceIdentifier: String
    ) -> [AutoFillCredentialIndexRecord] {
        guard let requestedHost = Self.normalizedHost(from: serviceIdentifier) else {
            return []
        }

        return records.filter { record in
            record.serviceIdentifiers.contains { candidate in
                guard let candidateHost = Self.normalizedHost(from: candidate) else {
                    return false
                }
                return requestedHost == candidateHost
                    || requestedHost.hasSuffix(".\(candidateHost)")
                    || candidateHost.hasSuffix(".\(requestedHost)")
            }
        }
    }

    private static func normalizedHost(from serviceIdentifier: String) -> String? {
        let trimmed = serviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let host = URL(string: trimmed)?.host(), !host.isEmpty {
            return host.lowercased()
        }

        if let host = URL(string: "https://\(trimmed)")?.host(), !host.isEmpty {
            return host.lowercased()
        }

        return nil
    }
}

public struct AutoFillCredentialIndexUnlocker: Sendable {
    private let codec: AutoFillEncryptedIndexCodec

    public init(codec: AutoFillEncryptedIndexCodec = AutoFillEncryptedIndexCodec()) {
        self.codec = codec
    }

    public func unlock(
        _ index: AutoFillEncryptedIndex,
        vaultID: String,
        keyIdentifier: String,
        key: AutoFillIndexEncryptionKey
    ) throws -> AutoFillUnlockedCredentialIndex {
        guard index.vaultID == vaultID else {
            throw AutoFillEncryptedIndexCodecError.vaultIdentifierMismatch(
                expected: vaultID,
                actual: index.vaultID
            )
        }
        guard index.keyIdentifier == keyIdentifier else {
            throw AutoFillEncryptedIndexCodecError.keyIdentifierMismatch(
                expected: keyIdentifier,
                actual: index.keyIdentifier
            )
        }

        return AutoFillUnlockedCredentialIndex(
            vaultID: index.vaultID,
            keyIdentifier: index.keyIdentifier,
            updatedAt: index.updatedAt,
            records: try codec.decrypt(index, key: key)
        )
    }
}

public struct AutoFillCredentialSecretCodec: Sendable {
    public init() {}

    public func encrypt(
        _ records: [AutoFillCredentialSecretRecord],
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        key: AutoFillIndexEncryptionKey
    ) throws -> AutoFillCredentialSecretSnapshot {
        let symmetricKey = SymmetricKey(data: key.rawValue)
        let encryptedRecords = try records.map { record in
            let plaintext = try Self.payloadEncoder.encode(record)
            let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey)
            return AutoFillEncryptedCredentialSecretRecord(
                id: record.id,
                nonce: Data(sealedBox.nonce),
                ciphertext: sealedBox.ciphertext,
                authenticationTag: sealedBox.tag
            )
        }

        return AutoFillCredentialSecretSnapshot(
            vaultID: vaultID,
            keyIdentifier: keyIdentifier,
            updatedAt: updatedAt,
            records: encryptedRecords
        )
    }

    public func decrypt(
        _ snapshot: AutoFillCredentialSecretSnapshot,
        key: AutoFillIndexEncryptionKey
    ) throws -> [AutoFillCredentialSecretRecord] {
        let symmetricKey = SymmetricKey(data: key.rawValue)
        return try snapshot.records.map { record in
            let nonce = try AES.GCM.Nonce(data: record.nonce)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: record.ciphertext,
                tag: record.authenticationTag
            )
            let plaintext = try AES.GCM.open(sealedBox, using: symmetricKey)
            return try Self.payloadDecoder.decode(
                AutoFillCredentialSecretRecord.self,
                from: plaintext
            )
        }
    }

    private static let payloadEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let payloadDecoder = JSONDecoder()
}

public struct AutoFillUnlockedCredentialSecretSnapshot: Sendable, Equatable {
    public let vaultID: String
    public let keyIdentifier: String
    public let updatedAt: Date
    public let records: [AutoFillCredentialSecretRecord]

    public init(
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        records: [AutoFillCredentialSecretRecord]
    ) {
        self.vaultID = vaultID
        self.keyIdentifier = keyIdentifier
        self.updatedAt = updatedAt
        self.records = records
    }

    public func secret(id: String) -> AutoFillCredentialSecretRecord? {
        records.first { $0.id == id }
    }
}

public struct AutoFillCredentialSecretUnlocker: Sendable {
    private let codec: AutoFillCredentialSecretCodec

    public init(codec: AutoFillCredentialSecretCodec = AutoFillCredentialSecretCodec()) {
        self.codec = codec
    }

    public func unlock(
        _ snapshot: AutoFillCredentialSecretSnapshot,
        vaultID: String,
        keyIdentifier: String,
        key: AutoFillIndexEncryptionKey
    ) throws -> AutoFillUnlockedCredentialSecretSnapshot {
        guard snapshot.vaultID == vaultID else {
            throw AutoFillEncryptedIndexCodecError.vaultIdentifierMismatch(
                expected: vaultID,
                actual: snapshot.vaultID
            )
        }
        guard snapshot.keyIdentifier == keyIdentifier else {
            throw AutoFillEncryptedIndexCodecError.keyIdentifierMismatch(
                expected: keyIdentifier,
                actual: snapshot.keyIdentifier
            )
        }

        return AutoFillUnlockedCredentialSecretSnapshot(
            vaultID: snapshot.vaultID,
            keyIdentifier: snapshot.keyIdentifier,
            updatedAt: snapshot.updatedAt,
            records: try codec.decrypt(snapshot, key: key)
        )
    }
}

public enum AutoFillCredentialResolverError: Error, Sendable, Equatable, LocalizedError {
    case credentialUnavailable
    case credentialSecretUnavailable

    public var errorDescription: String? {
        switch self {
        case .credentialUnavailable:
            return "自动填充凭据不可用。"
        case .credentialSecretUnavailable:
            return "自动填充凭据密钥不可用。"
        }
    }
}

public struct AutoFillCredentialResolver: Sendable {
    public let index: AutoFillUnlockedCredentialIndex
    public let secrets: AutoFillUnlockedCredentialSecretSnapshot

    public init(
        index: AutoFillUnlockedCredentialIndex,
        secrets: AutoFillUnlockedCredentialSecretSnapshot
    ) {
        self.index = index
        self.secrets = secrets
    }

    public func records(
        matchingServiceIdentifiers serviceIdentifiers: [String]
    ) -> [AutoFillCredentialIndexRecord] {
        guard !serviceIdentifiers.isEmpty else {
            return index.records
        }

        var matchedRecords: [AutoFillCredentialIndexRecord] = []
        for serviceIdentifier in serviceIdentifiers {
            matchedRecords.append(
                contentsOf: index.records(
                    matchingServiceIdentifier: serviceIdentifier
                )
            )
        }

        return deduplicated(matchedRecords)
    }

    public func search(
        _ query: String,
        within records: [AutoFillCredentialIndexRecord]
    ) -> [AutoFillCredentialIndexRecord] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return records
        }

        let recordIDs = Set(records.map(\.id))
        return index.search(trimmedQuery).filter { recordIDs.contains($0.id) }
    }

    public func credential(
        recordIdentifier: String
    ) throws -> AutoFillCredentialSecretRecord {
        let trimmedIdentifier = recordIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard index.records.contains(where: { $0.id == trimmedIdentifier }) else {
            throw AutoFillCredentialResolverError.credentialUnavailable
        }
        guard let secret = secrets.secret(id: trimmedIdentifier) else {
            throw AutoFillCredentialResolverError.credentialSecretUnavailable
        }
        return secret
    }

    public func credential(
        for record: AutoFillCredentialIndexRecord
    ) throws -> AutoFillCredentialSecretRecord {
        try credential(recordIdentifier: record.id)
    }

    private func deduplicated(
        _ records: [AutoFillCredentialIndexRecord]
    ) -> [AutoFillCredentialIndexRecord] {
        var seen = Set<String>()
        return records.filter { record in
            seen.insert(record.id).inserted
        }
    }
}

public struct FileAutoFillEncryptedIndexStore: AutoFillEncryptedIndexStore {
    public static let indexFileName = "autofill-index-v1.json"

    public let appGroupContainerURL: URL
    public let indexFileURL: URL

    public init(appGroupContainerURL: URL) {
        self.appGroupContainerURL = appGroupContainerURL
        self.indexFileURL = appGroupContainerURL.appendingPathComponent(
            FileAutoFillEncryptedIndexStore.indexFileName,
            isDirectory: false
        )
    }

    public func save(_ index: AutoFillEncryptedIndex) throws {
        try FileManager.default.createDirectory(
            at: appGroupContainerURL,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: indexFileURL, options: fileWritingOptions)
    }

    public func load() throws -> AutoFillEncryptedIndex? {
        guard FileManager.default.fileExists(atPath: indexFileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: indexFileURL)
        return try JSONDecoder().decode(AutoFillEncryptedIndex.self, from: data)
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: indexFileURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: indexFileURL)
    }

    private var fileWritingOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }
}

public struct FileAutoFillCredentialSecretStore: AutoFillCredentialSecretStore {
    public static let secretFileName = "autofill-secrets-v1.json"

    public let appGroupContainerURL: URL
    public let secretFileURL: URL

    public init(appGroupContainerURL: URL) {
        self.appGroupContainerURL = appGroupContainerURL
        self.secretFileURL = appGroupContainerURL.appendingPathComponent(
            FileAutoFillCredentialSecretStore.secretFileName,
            isDirectory: false
        )
    }

    public func save(_ snapshot: AutoFillCredentialSecretSnapshot) throws {
        try FileManager.default.createDirectory(
            at: appGroupContainerURL,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: secretFileURL, options: fileWritingOptions)
    }

    public func load() throws -> AutoFillCredentialSecretSnapshot? {
        guard FileManager.default.fileExists(atPath: secretFileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: secretFileURL)
        return try JSONDecoder().decode(AutoFillCredentialSecretSnapshot.self, from: data)
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: secretFileURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: secretFileURL)
    }

    private var fileWritingOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }
}

public struct LocalVaultRepository {
    private let engine: any LocalVaultEngine

    public init(engine: any LocalVaultEngine = MDBXLocalVaultEngine()) {
        self.engine = engine
    }

    public func entryRepository(for session: LocalVaultSession) -> LocalVaultEntryRepository {
        LocalVaultEntryRepository(session: session, engine: engine)
    }

    public func closeVault(for session: LocalVaultSession) {
        engine.closeVault(session.handle)
    }

    public func createVault(
        named name: String,
        in directoryURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultSession {
        let displayName = try normalizedVaultName(name)
        try validatePassword(password)

        let fileURL = directoryURL.appendingPathComponent(
            "\(displayName).mdbx",
            isDirectory: false
        )
        let handle = try engine.createVault(
            at: fileURL,
            password: password,
            deviceID: deviceID
        )
        return LocalVaultSession(
            descriptor: LocalVaultDescriptor(fileURL: fileURL, displayName: displayName),
            handle: handle,
            state: .unlocked
        )
    }

    public func openVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultSession {
        try validatePassword(password)

        let handle = try engine.openVault(
            at: fileURL,
            password: password,
            deviceID: deviceID
        )
        return LocalVaultSession(
            descriptor: LocalVaultDescriptor(
                fileURL: fileURL,
                displayName: fileURL.deletingPathExtension().lastPathComponent
            ),
            handle: handle,
            state: .unlocked
        )
    }

    public func openVaultWithSecurityKey(
        at fileURL: URL,
        securityKeyMaterial: Data,
        deviceID: String
    ) throws -> LocalVaultSession {
        try validateSecurityKeyMaterial(securityKeyMaterial)

        let handle = try engine.openVaultWithSecurityKey(
            at: fileURL,
            securityKeyMaterial: securityKeyMaterial,
            deviceID: deviceID
        )
        return LocalVaultSession(
            descriptor: LocalVaultDescriptor(
                fileURL: fileURL,
                displayName: fileURL.deletingPathExtension().lastPathComponent
            ),
            handle: handle,
            state: .unlocked
        )
    }

    public func setupLocalSecurityKeyUnlock(
        for session: LocalVaultSession,
        securityKeyMaterial: Data
    ) throws {
        try validateSecurityKeyMaterial(securityKeyMaterial)
        try engine.setupLocalSecurityKeyUnlock(
            in: session.handle,
            securityKeyMaterial: securityKeyMaterial
        )
    }

    public func resetMasterPassword(
        for session: LocalVaultSession,
        newPassword: String
    ) throws {
        try validatePassword(newPassword)
        try engine.resetMasterPassword(
            in: session.handle,
            newPassword: newPassword
        )
    }

    private func normalizedVaultName(_ name: String) throws -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LocalVaultRepositoryError.emptyVaultName
        }
        return normalized
    }

    private func validatePassword(_ password: String) throws {
        guard !password.isEmpty else {
            throw LocalVaultRepositoryError.emptyPassword
        }
    }

    private func validateSecurityKeyMaterial(_ securityKeyMaterial: Data) throws {
        guard !securityKeyMaterial.isEmpty else {
            throw LocalVaultRepositoryError.emptySecurityKeyMaterial
        }
    }
}

public struct LocalVaultEntryRepository {
    private let session: LocalVaultSession
    private let engine: any LocalVaultEngine

    public init(
        session: LocalVaultSession,
        engine: any LocalVaultEngine
    ) {
        self.session = session
        self.engine = engine
    }

    public func createProject(title: String) throws -> LocalVaultProject {
        let normalizedTitle = try normalizedProjectTitle(title)
        return try engine.createProject(
            in: session.handle,
            title: normalizedTitle
        )
    }

    public func listProjects() throws -> [LocalVaultProject] {
        try engine.listProjects(in: session.handle)
    }

    public func renameProject(
        projectID: String,
        title: String
    ) throws -> LocalVaultProject {
        let normalizedTitle = try normalizedProjectTitle(title)
        return try engine.renameProject(
            in: session.handle,
            projectID: projectID,
            title: normalizedTitle
        )
    }

    public func deleteProject(projectID: String) throws {
        try engine.deleteProject(
            in: session.handle,
            projectID: projectID
        )
    }

    public func moveEntry(
        kind: UnifiedVaultItemKind,
        entryID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws -> LocalVaultMovedEntry {
        try engine.moveEntry(
            in: session.handle,
            kind: kind,
            entryID: entryID,
            fromProjectID: fromProjectID,
            toProjectID: toProjectID
        )
    }

    public func createLoginEntry(
        projectID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let normalizedDraft = try normalizedLoginEntryDraft(draft)
        return try engine.createLoginEntry(
            in: session.handle,
            projectID: projectID,
            draft: normalizedDraft
        )
    }

    public func listLoginEntries(projectID: String) throws -> [LocalLoginEntry] {
        try engine.listLoginEntries(
            in: session.handle,
            projectID: projectID
        )
    }

    public func updateLoginEntry(
        projectID: String,
        entryID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let normalizedDraft = try normalizedLoginEntryDraft(draft)
        return try engine.updateLoginEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            draft: normalizedDraft
        )
    }

    public func setLoginEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalLoginEntry {
        try engine.setLoginEntryFavorite(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
    }

    public func deleteLoginEntry(projectID: String, entryID: String) throws {
        try engine.deleteLoginEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func listDeletedLoginEntries(projectID: String) throws -> [LocalLoginEntry] {
        try engine.listDeletedLoginEntries(
            in: session.handle,
            projectID: projectID
        )
    }

    public func restoreLoginEntry(
        projectID: String,
        entryID: String
    ) throws -> LocalLoginEntry {
        try engine.restoreLoginEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func createNoteEntry(
        projectID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let normalizedDraft = try normalizedNoteEntryDraft(draft)
        return try engine.createNoteEntry(
            in: session.handle,
            projectID: projectID,
            draft: normalizedDraft
        )
    }

    public func listNoteEntries(projectID: String) throws -> [LocalNoteEntry] {
        try engine.listNoteEntries(in: session.handle, projectID: projectID)
    }

    public func updateNoteEntry(
        projectID: String,
        entryID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let normalizedDraft = try normalizedNoteEntryDraft(draft)
        return try engine.updateNoteEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            draft: normalizedDraft
        )
    }

    public func setNoteEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalNoteEntry {
        try engine.setNoteEntryFavorite(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
    }

    public func deleteNoteEntry(projectID: String, entryID: String) throws {
        try engine.deleteNoteEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func listDeletedNoteEntries(projectID: String) throws -> [LocalNoteEntry] {
        try engine.listDeletedNoteEntries(in: session.handle, projectID: projectID)
    }

    public func restoreNoteEntry(
        projectID: String,
        entryID: String
    ) throws -> LocalNoteEntry {
        try engine.restoreNoteEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func createTotpEntry(
        projectID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let normalizedDraft = try normalizedTotpEntryDraft(draft)
        return try engine.createTotpEntry(
            in: session.handle,
            projectID: projectID,
            draft: normalizedDraft
        )
    }

    public func listTotpEntries(projectID: String) throws -> [LocalTotpEntry] {
        try engine.listTotpEntries(in: session.handle, projectID: projectID)
    }

    public func updateTotpEntry(
        projectID: String,
        entryID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let normalizedDraft = try normalizedTotpEntryDraft(draft)
        return try engine.updateTotpEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            draft: normalizedDraft
        )
    }

    public func setTotpEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalTotpEntry {
        try engine.setTotpEntryFavorite(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
    }

    public func deleteTotpEntry(projectID: String, entryID: String) throws {
        try engine.deleteTotpEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func listDeletedTotpEntries(projectID: String) throws -> [LocalTotpEntry] {
        try engine.listDeletedTotpEntries(in: session.handle, projectID: projectID)
    }

    public func restoreTotpEntry(
        projectID: String,
        entryID: String
    ) throws -> LocalTotpEntry {
        try engine.restoreTotpEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func createCardEntry(
        projectID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let normalizedDraft = try normalizedCardEntryDraft(draft)
        return try engine.createCardEntry(
            in: session.handle,
            projectID: projectID,
            draft: normalizedDraft
        )
    }

    public func listCardEntries(projectID: String) throws -> [LocalCardEntry] {
        try engine.listCardEntries(in: session.handle, projectID: projectID)
    }

    public func updateCardEntry(
        projectID: String,
        entryID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let normalizedDraft = try normalizedCardEntryDraft(draft)
        return try engine.updateCardEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            draft: normalizedDraft
        )
    }

    public func setCardEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalCardEntry {
        try engine.setCardEntryFavorite(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
    }

    public func deleteCardEntry(projectID: String, entryID: String) throws {
        try engine.deleteCardEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func listDeletedCardEntries(projectID: String) throws -> [LocalCardEntry] {
        try engine.listDeletedCardEntries(in: session.handle, projectID: projectID)
    }

    public func restoreCardEntry(
        projectID: String,
        entryID: String
    ) throws -> LocalCardEntry {
        try engine.restoreCardEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func createIdentityEntry(
        projectID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let normalizedDraft = try normalizedIdentityEntryDraft(draft)
        return try engine.createIdentityEntry(
            in: session.handle,
            projectID: projectID,
            draft: normalizedDraft
        )
    }

    public func listIdentityEntries(projectID: String) throws -> [LocalIdentityEntry] {
        try engine.listIdentityEntries(in: session.handle, projectID: projectID)
    }

    public func updateIdentityEntry(
        projectID: String,
        entryID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let normalizedDraft = try normalizedIdentityEntryDraft(draft)
        return try engine.updateIdentityEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            draft: normalizedDraft
        )
    }

    public func setIdentityEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalIdentityEntry {
        try engine.setIdentityEntryFavorite(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
    }

    public func deleteIdentityEntry(projectID: String, entryID: String) throws {
        try engine.deleteIdentityEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func listDeletedIdentityEntries(projectID: String) throws -> [LocalIdentityEntry] {
        try engine.listDeletedIdentityEntries(in: session.handle, projectID: projectID)
    }

    public func restoreIdentityEntry(
        projectID: String,
        entryID: String
    ) throws -> LocalIdentityEntry {
        try engine.restoreIdentityEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func createPasskeyEntry(projectID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry {
        try engine.createPasskeyEntry(in: session.handle, projectID: projectID, draft: normalizedPasskeyEntryDraft(draft))
    }

    public func listPasskeyEntries(projectID: String) throws -> [LocalPasskeyEntry] {
        try engine.listPasskeyEntries(in: session.handle, projectID: projectID)
    }

    public func updatePasskeyEntry(projectID: String, entryID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry {
        try engine.updatePasskeyEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedPasskeyEntryDraft(draft))
    }

    public func setPasskeyEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalPasskeyEntry {
        try engine.setPasskeyEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deletePasskeyEntry(projectID: String, entryID: String) throws {
        try engine.deletePasskeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedPasskeyEntries(projectID: String) throws -> [LocalPasskeyEntry] {
        try engine.listDeletedPasskeyEntries(in: session.handle, projectID: projectID)
    }

    public func restorePasskeyEntry(projectID: String, entryID: String) throws -> LocalPasskeyEntry {
        try engine.restorePasskeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func createSshKeyEntry(projectID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        try engine.createSshKeyEntry(in: session.handle, projectID: projectID, draft: normalizedSshKeyEntryDraft(draft))
    }

    public func listSshKeyEntries(projectID: String) throws -> [LocalSshKeyEntry] {
        try engine.listSshKeyEntries(in: session.handle, projectID: projectID)
    }

    public func updateSshKeyEntry(projectID: String, entryID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        try engine.updateSshKeyEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedSshKeyEntryDraft(draft))
    }

    public func setSshKeyEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalSshKeyEntry {
        try engine.setSshKeyEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteSshKeyEntry(projectID: String, entryID: String) throws {
        try engine.deleteSshKeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedSshKeyEntries(projectID: String) throws -> [LocalSshKeyEntry] {
        try engine.listDeletedSshKeyEntries(in: session.handle, projectID: projectID)
    }

    public func restoreSshKeyEntry(projectID: String, entryID: String) throws -> LocalSshKeyEntry {
        try engine.restoreSshKeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func createApiTokenEntry(projectID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        try engine.createApiTokenEntry(in: session.handle, projectID: projectID, draft: normalizedApiTokenEntryDraft(draft))
    }

    public func listApiTokenEntries(projectID: String) throws -> [LocalApiTokenEntry] {
        try engine.listApiTokenEntries(in: session.handle, projectID: projectID)
    }

    public func updateApiTokenEntry(projectID: String, entryID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        try engine.updateApiTokenEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedApiTokenEntryDraft(draft))
    }

    public func setApiTokenEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalApiTokenEntry {
        try engine.setApiTokenEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteApiTokenEntry(projectID: String, entryID: String) throws {
        try engine.deleteApiTokenEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedApiTokenEntries(projectID: String) throws -> [LocalApiTokenEntry] {
        try engine.listDeletedApiTokenEntries(in: session.handle, projectID: projectID)
    }

    public func restoreApiTokenEntry(projectID: String, entryID: String) throws -> LocalApiTokenEntry {
        try engine.restoreApiTokenEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func createWifiEntry(projectID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        try engine.createWifiEntry(in: session.handle, projectID: projectID, draft: normalizedWifiEntryDraft(draft))
    }

    public func listWifiEntries(projectID: String) throws -> [LocalWifiEntry] {
        try engine.listWifiEntries(in: session.handle, projectID: projectID)
    }

    public func updateWifiEntry(projectID: String, entryID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        try engine.updateWifiEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedWifiEntryDraft(draft))
    }

    public func setWifiEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalWifiEntry {
        try engine.setWifiEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteWifiEntry(projectID: String, entryID: String) throws {
        try engine.deleteWifiEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedWifiEntries(projectID: String) throws -> [LocalWifiEntry] {
        try engine.listDeletedWifiEntries(in: session.handle, projectID: projectID)
    }

    public func restoreWifiEntry(projectID: String, entryID: String) throws -> LocalWifiEntry {
        try engine.restoreWifiEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func createSendEntry(projectID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry {
        try engine.createSendEntry(in: session.handle, projectID: projectID, draft: normalizedSendEntryDraft(draft))
    }

    public func listSendEntries(projectID: String) throws -> [LocalSendEntry] {
        try engine.listSendEntries(in: session.handle, projectID: projectID)
    }

    public func updateSendEntry(projectID: String, entryID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry {
        try engine.updateSendEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedSendEntryDraft(draft))
    }

    public func setSendEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalSendEntry {
        try engine.setSendEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteSendEntry(projectID: String, entryID: String) throws {
        try engine.deleteSendEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedSendEntries(projectID: String) throws -> [LocalSendEntry] {
        try engine.listDeletedSendEntries(in: session.handle, projectID: projectID)
    }

    public func restoreSendEntry(projectID: String, entryID: String) throws -> LocalSendEntry {
        try engine.restoreSendEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func createAttachmentMetadata(
        projectID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String = "",
        downloadState: String = "",
        wrappedContentEncryptionKey: String? = nil,
        localPath: String? = nil
    ) throws -> LocalAttachmentMetadata {
        let normalizedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFileName.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return try engine.createAttachmentMetadata(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            fileName: normalizedFileName,
            mediaType: mediaType,
            originalSize: originalSize,
            storedSize: storedSize,
            contentHash: contentHash,
            storageMode: storageMode,
            source: source,
            downloadState: downloadState,
            wrappedContentEncryptionKey: wrappedContentEncryptionKey,
            localPath: localPath
        )
    }

    public func listAttachmentMetadata(projectID: String) throws -> [LocalAttachmentMetadata] {
        try engine.listAttachmentMetadata(in: session.handle, projectID: projectID)
    }

    public func updateAttachmentMetadata(
        projectID: String,
        attachmentID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String = "",
        downloadState: String = "",
        wrappedContentEncryptionKey: String? = nil,
        localPath: String? = nil
    ) throws -> LocalAttachmentMetadata {
        let normalizedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFileName.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return try engine.updateAttachmentMetadata(
            in: session.handle,
            projectID: projectID,
            attachmentID: attachmentID,
            entryID: entryID,
            fileName: normalizedFileName,
            mediaType: mediaType,
            originalSize: originalSize,
            storedSize: storedSize,
            contentHash: contentHash,
            storageMode: storageMode,
            source: source,
            downloadState: downloadState,
            wrappedContentEncryptionKey: wrappedContentEncryptionKey,
            localPath: localPath
        )
    }

    public func deleteAttachmentMetadata(projectID: String, attachmentID: String) throws {
        try engine.deleteAttachmentMetadata(in: session.handle, projectID: projectID, attachmentID: attachmentID)
    }

    public func listDeletedAttachmentMetadata(projectID: String) throws -> [LocalAttachmentMetadata] {
        try engine.listDeletedAttachmentMetadata(in: session.handle, projectID: projectID)
    }

    public func restoreAttachmentMetadata(projectID: String, attachmentID: String) throws -> LocalAttachmentMetadata {
        try engine.restoreAttachmentMetadata(in: session.handle, projectID: projectID, attachmentID: attachmentID)
    }

    private func normalizedProjectTitle(_ title: String) throws -> String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LocalVaultRepositoryError.emptyProjectTitle
        }
        return normalized
    }

    private func normalizedLoginEntryDraft(_ draft: LocalLoginEntryDraft) throws -> LocalLoginEntryDraft {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return LocalLoginEntryDraft(
            title: normalizedTitle,
            username: draft.username,
            password: draft.password,
            url: draft.url,
            notes: draft.notes
        )
    }

    private func normalizedNoteEntryDraft(_ draft: LocalNoteEntryDraft) throws -> LocalNoteEntryDraft {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return LocalNoteEntryDraft(title: normalizedTitle, body: draft.body)
    }

    private func normalizedTotpEntryDraft(_ draft: LocalTotpEntryDraft) throws -> LocalTotpEntryDraft {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return LocalTotpEntryDraft(
            title: normalizedTitle,
            secret: draft.secret,
            issuer: draft.issuer,
            accountName: draft.accountName,
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm,
            otpType: draft.otpType,
            counter: draft.counter
        )
    }

    private func normalizedCardEntryDraft(_ draft: LocalCardEntryDraft) throws -> LocalCardEntryDraft {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return LocalCardEntryDraft(
            title: normalizedTitle,
            cardholderName: draft.cardholderName,
            number: draft.number,
            expiryMonth: draft.expiryMonth,
            expiryYear: draft.expiryYear,
            cvv: draft.cvv,
            issuer: draft.issuer,
            network: draft.network,
            notes: draft.notes
        )
    }

    private func normalizedIdentityEntryDraft(_ draft: LocalIdentityEntryDraft) throws -> LocalIdentityEntryDraft {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return LocalIdentityEntryDraft(
            title: normalizedTitle,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes
        )
    }

    private func normalizedPasskeyEntryDraft(_ draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalPasskeyEntryDraft(
            title: normalizedTitle,
            relyingPartyID: draft.relyingPartyID,
            username: draft.username,
            userHandle: draft.userHandle,
            credentialID: draft.credentialID,
            publicKeyCOSE: draft.publicKeyCOSE,
            privateKeyReference: draft.privateKeyReference,
            notes: draft.notes
        )
    }

    private func normalizedSshKeyEntryDraft(_ draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalSshKeyEntryDraft(
            title: normalizedTitle,
            username: draft.username,
            host: draft.host,
            publicKey: draft.publicKey,
            privateKeyReference: draft.privateKeyReference,
            passphraseHint: draft.passphraseHint,
            notes: draft.notes
        )
    }

    private func normalizedApiTokenEntryDraft(_ draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalApiTokenEntryDraft(
            title: normalizedTitle,
            issuer: draft.issuer,
            accountName: draft.accountName,
            token: draft.token,
            scopes: draft.scopes,
            expiresAt: draft.expiresAt,
            notes: draft.notes
        )
    }

    private func normalizedWifiEntryDraft(_ draft: LocalWifiEntryDraft) throws -> LocalWifiEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalWifiEntryDraft(
            title: normalizedTitle,
            ssid: draft.ssid,
            securityType: draft.securityType,
            password: draft.password,
            hidden: draft.hidden,
            notes: draft.notes
        )
    }

    private func normalizedSendEntryDraft(_ draft: LocalSendEntryDraft) throws -> LocalSendEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalSendEntryDraft(
            title: normalizedTitle,
            body: draft.body,
            expiresAt: draft.expiresAt,
            maxViews: draft.maxViews,
            notes: draft.notes
        )
    }

    private func normalizedEntryTitle(_ title: String) throws -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return normalizedTitle
    }
}

public final class MDBXLocalVaultEngine: LocalVaultEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var vaults: [String: MonicaMDBXVault] = [:]
    private var projects: [String: [LocalVaultProject]] = [:]

    public init() {}

    public func createVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle {
        let vault = try MonicaMDBXRuntime.createVault(
            at: fileURL,
            password: password,
            deviceID: deviceID
        )
        let info = vault.info()
        store(vault, vaultID: info.vaultID)
        return LocalVaultHandle(vaultID: info.vaultID, deviceID: info.deviceID)
    }

    public func openVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle {
        let vault = try MonicaMDBXRuntime.openVault(
            at: fileURL,
            password: password,
            deviceID: deviceID
        )
        let info = vault.info()
        store(vault, vaultID: info.vaultID)
        return LocalVaultHandle(vaultID: info.vaultID, deviceID: info.deviceID)
    }

    public func openVaultWithSecurityKey(
        at fileURL: URL,
        securityKeyMaterial: Data,
        deviceID: String
    ) throws -> LocalVaultHandle {
        let vault = try MonicaMDBXRuntime.openVaultWithSecurityKey(
            at: fileURL,
            securityKeyMaterial: securityKeyMaterial,
            deviceID: deviceID
        )
        let info = vault.info()
        store(vault, vaultID: info.vaultID)
        return LocalVaultHandle(vaultID: info.vaultID, deviceID: info.deviceID)
    }

    public func setupLocalSecurityKeyUnlock(
        in handle: LocalVaultHandle,
        securityKeyMaterial: Data
    ) throws {
        try vault(for: handle).setupLocalSecurityKeyUnlock(securityKeyMaterial)
    }

    public func resetMasterPassword(
        in handle: LocalVaultHandle,
        newPassword: String
    ) throws {
        try vault(for: handle).resetMasterPassword(newPassword)
    }

    public func closeVault(_ handle: LocalVaultHandle) {
        lock.lock()
        defer { lock.unlock() }
        vaults.removeValue(forKey: handle.vaultID)
        projects.removeValue(forKey: handle.vaultID)
    }

    public func createProject(
        in handle: LocalVaultHandle,
        title: String
    ) throws -> LocalVaultProject {
        let project = try vault(for: handle).createProject(title: title)
        let localProject = LocalVaultProject(id: project.id, title: project.title)
        lock.lock()
        projects[handle.vaultID, default: []].append(localProject)
        lock.unlock()
        return localProject
    }

    public func listProjects(in handle: LocalVaultHandle) throws -> [LocalVaultProject] {
        _ = try vault(for: handle)
        lock.lock()
        defer { lock.unlock() }
        return projects[handle.vaultID, default: []]
    }

    public func renameProject(
        in handle: LocalVaultHandle,
        projectID: String,
        title: String
    ) throws -> LocalVaultProject {
        _ = try vault(for: handle)
        lock.lock()
        defer { lock.unlock() }
        guard let index = projects[handle.vaultID, default: []].firstIndex(where: { $0.id == projectID }) else {
            throw LocalVaultRepositoryError.projectNotFound
        }
        let renamed = LocalVaultProject(id: projectID, title: title)
        projects[handle.vaultID, default: []][index] = renamed
        return renamed
    }

    public func deleteProject(in handle: LocalVaultHandle, projectID: String) throws {
        _ = try vault(for: handle)
        guard try !projectContainsEntries(handle: handle, projectID: projectID) else {
            throw LocalVaultRepositoryError.projectNotEmpty
        }
        lock.lock()
        defer { lock.unlock() }
        guard projects[handle.vaultID, default: []].contains(where: { $0.id == projectID }) else {
            throw LocalVaultRepositoryError.projectNotFound
        }
        projects[handle.vaultID, default: []].removeAll { $0.id == projectID }
    }

    public func moveEntry(
        in handle: LocalVaultHandle,
        kind: UnifiedVaultItemKind,
        entryID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws -> LocalVaultMovedEntry {
        switch kind {
        case .login:
            let entry = try vault(for: handle).moveLoginEntry(
                projectID: fromProjectID,
                entryID: entryID,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        case .note:
            let entry = try vault(for: handle).moveNoteEntry(
                projectID: fromProjectID,
                entryID: entryID,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        case .totp:
            let entry = try vault(for: handle).moveTotpEntry(
                projectID: fromProjectID,
                entryID: entryID,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        case .card:
            let entry = try vault(for: handle).moveCardEntry(
                projectID: fromProjectID,
                entryID: entryID,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        case .identity:
            let entry = try vault(for: handle).moveIdentityEntry(
                projectID: fromProjectID,
                entryID: entryID,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        case .passkey, .sshKey, .apiToken, .wifi, .send, .attachmentRef:
            let mapping = parityMoveMapping(for: kind)
            let entry = try moveParityEntry(
                in: handle,
                projectID: fromProjectID,
                entryID: entryID,
                entryType: mapping.entryType,
                kind: mapping.kind,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        }
    }

    public func createLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let entry = try vault(for: handle).createLoginEntry(
            projectID: projectID,
            title: draft.title,
            username: draft.username,
            password: draft.password,
            url: draft.url,
            notes: draft.notes
        )
        return LocalLoginEntry(entry)
    }

    public func listLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry] {
        try vault(for: handle)
            .listLoginEntries(projectID: projectID)
            .map(LocalLoginEntry.init)
    }

    public func updateLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let entry = try vault(for: handle).updateLoginEntry(
            projectID: projectID,
            entryID: entryID,
            title: draft.title,
            username: draft.username,
            password: draft.password,
            url: draft.url,
            notes: draft.notes
        )
        return LocalLoginEntry(entry)
    }

    public func deleteLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        try vault(for: handle).deleteLoginEntry(projectID: projectID, entryID: entryID)
    }

    public func setLoginEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalLoginEntry {
        let entry = try vault(for: handle).setLoginEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
        return LocalLoginEntry(entry)
    }

    public func listDeletedLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry] {
        try vault(for: handle)
            .listDeletedLoginEntries(projectID: projectID)
            .map(LocalLoginEntry.init)
    }

    public func restoreLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalLoginEntry {
        let entry = try vault(for: handle).restoreLoginEntry(
            projectID: projectID,
            entryID: entryID
        )
        return LocalLoginEntry(entry)
    }

    public func createNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let entry = try vault(for: handle).createNoteEntry(
            projectID: projectID,
            title: draft.title,
            body: draft.body
        )
        return LocalNoteEntry(entry)
    }

    public func listNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry] {
        try vault(for: handle)
            .listNoteEntries(projectID: projectID)
            .map(LocalNoteEntry.init)
    }

    public func updateNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let entry = try vault(for: handle).updateNoteEntry(
            projectID: projectID,
            entryID: entryID,
            title: draft.title,
            body: draft.body
        )
        return LocalNoteEntry(entry)
    }

    public func setNoteEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalNoteEntry {
        let entry = try vault(for: handle).setNoteEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
        return LocalNoteEntry(entry)
    }

    public func deleteNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        try vault(for: handle).deleteNoteEntry(projectID: projectID, entryID: entryID)
    }

    public func listDeletedNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry] {
        try vault(for: handle)
            .listDeletedNoteEntries(projectID: projectID)
            .map(LocalNoteEntry.init)
    }

    public func restoreNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalNoteEntry {
        let entry = try vault(for: handle).restoreNoteEntry(
            projectID: projectID,
            entryID: entryID
        )
        return LocalNoteEntry(entry)
    }

    public func createTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let entry = try vault(for: handle).createTotpEntry(
            projectID: projectID,
            title: draft.title,
            secret: draft.secret,
            issuer: draft.issuer,
            accountName: draft.accountName,
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm,
            otpType: draft.otpType,
            counter: draft.counter
        )
        return LocalTotpEntry(entry)
    }

    public func listTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry] {
        try vault(for: handle)
            .listTotpEntries(projectID: projectID)
            .map(LocalTotpEntry.init)
    }

    public func updateTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let entry = try vault(for: handle).updateTotpEntry(
            projectID: projectID,
            entryID: entryID,
            title: draft.title,
            secret: draft.secret,
            issuer: draft.issuer,
            accountName: draft.accountName,
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm,
            otpType: draft.otpType,
            counter: draft.counter
        )
        return LocalTotpEntry(entry)
    }

    public func setTotpEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalTotpEntry {
        let entry = try vault(for: handle).setTotpEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
        return LocalTotpEntry(entry)
    }

    public func deleteTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        try vault(for: handle).deleteTotpEntry(projectID: projectID, entryID: entryID)
    }

    public func listDeletedTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry] {
        try vault(for: handle)
            .listDeletedTotpEntries(projectID: projectID)
            .map(LocalTotpEntry.init)
    }

    public func restoreTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalTotpEntry {
        let entry = try vault(for: handle).restoreTotpEntry(
            projectID: projectID,
            entryID: entryID
        )
        return LocalTotpEntry(entry)
    }

    public func createCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let entry = try vault(for: handle).createCardEntry(
            projectID: projectID,
            title: draft.title,
            cardholderName: draft.cardholderName,
            number: draft.number,
            expiryMonth: draft.expiryMonth,
            expiryYear: draft.expiryYear,
            cvv: draft.cvv,
            issuer: draft.issuer,
            network: draft.network,
            notes: draft.notes
        )
        return LocalCardEntry(entry)
    }

    public func listCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry] {
        try vault(for: handle)
            .listCardEntries(projectID: projectID)
            .map(LocalCardEntry.init)
    }

    public func updateCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let entry = try vault(for: handle).updateCardEntry(
            projectID: projectID,
            entryID: entryID,
            title: draft.title,
            cardholderName: draft.cardholderName,
            number: draft.number,
            expiryMonth: draft.expiryMonth,
            expiryYear: draft.expiryYear,
            cvv: draft.cvv,
            issuer: draft.issuer,
            network: draft.network,
            notes: draft.notes
        )
        return LocalCardEntry(entry)
    }

    public func setCardEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalCardEntry {
        let entry = try vault(for: handle).setCardEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
        return LocalCardEntry(entry)
    }

    public func deleteCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        try vault(for: handle).deleteCardEntry(projectID: projectID, entryID: entryID)
    }

    public func listDeletedCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry] {
        try vault(for: handle)
            .listDeletedCardEntries(projectID: projectID)
            .map(LocalCardEntry.init)
    }

    public func restoreCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalCardEntry {
        let entry = try vault(for: handle).restoreCardEntry(
            projectID: projectID,
            entryID: entryID
        )
        return LocalCardEntry(entry)
    }

    public func createIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let entry = try vault(for: handle).createIdentityEntry(
            projectID: projectID,
            title: draft.title,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes
        )
        return LocalIdentityEntry(entry)
    }

    public func listIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry] {
        try vault(for: handle)
            .listIdentityEntries(projectID: projectID)
            .map(LocalIdentityEntry.init)
    }

    public func updateIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let entry = try vault(for: handle).updateIdentityEntry(
            projectID: projectID,
            entryID: entryID,
            title: draft.title,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes
        )
        return LocalIdentityEntry(entry)
    }

    public func setIdentityEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalIdentityEntry {
        let entry = try vault(for: handle).setIdentityEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
        return LocalIdentityEntry(entry)
    }

    public func deleteIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        try vault(for: handle).deleteIdentityEntry(projectID: projectID, entryID: entryID)
    }

    public func listDeletedIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry] {
        try vault(for: handle)
            .listDeletedIdentityEntries(projectID: projectID)
            .map(LocalIdentityEntry.init)
    }

    public func restoreIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalIdentityEntry {
        let entry = try vault(for: handle).restoreIdentityEntry(
            projectID: projectID,
            entryID: entryID
        )
        return LocalIdentityEntry(entry)
    }

    public func createPasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalPasskeyEntryDraft
    ) throws -> LocalPasskeyEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "passkey",
            kind: "passkey",
            title: draft.title,
            payload: [
                "relyingPartyID": draft.relyingPartyID,
                "username": draft.username,
                "userHandle": draft.userHandle,
                "credentialID": draft.credentialID,
                "publicKeyCOSE": draft.publicKeyCOSE,
                "privateKeyReference": draft.privateKeyReference,
                "notes": draft.notes
            ]
        )
        return try LocalPasskeyEntry(entry)
    }

    public func listPasskeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPasskeyEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "passkey", kind: "passkey").map(LocalPasskeyEntry.init)
    }

    public func updatePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "passkey",
            kind: "passkey",
            title: draft.title,
            payload: [
                "relyingPartyID": draft.relyingPartyID,
                "username": draft.username,
                "userHandle": draft.userHandle,
                "credentialID": draft.credentialID,
                "publicKeyCOSE": draft.publicKeyCOSE,
                "privateKeyReference": draft.privateKeyReference,
                "notes": draft.notes
            ]
        )
        return try LocalPasskeyEntry(entry)
    }

    public func setPasskeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalPasskeyEntry {
        try LocalPasskeyEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "passkey", kind: "passkey", favorite: favorite))
    }

    public func deletePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "passkey", kind: "passkey")
    }

    public func listDeletedPasskeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPasskeyEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "passkey", kind: "passkey").map(LocalPasskeyEntry.init)
    }

    public func restorePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalPasskeyEntry {
        try LocalPasskeyEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "passkey", kind: "passkey"))
    }

    public func createSshKeyEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "ssh-key",
            kind: "ssh-key",
            title: draft.title,
            payload: [
                "username": draft.username,
                "host": draft.host,
                "publicKey": draft.publicKey,
                "privateKeyReference": draft.privateKeyReference,
                "passphraseHint": draft.passphraseHint,
                "notes": draft.notes
            ]
        )
        return try LocalSshKeyEntry(entry)
    }

    public func listSshKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSshKeyEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "ssh-key", kind: "ssh-key").map(LocalSshKeyEntry.init)
    }

    public func updateSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "ssh-key",
            kind: "ssh-key",
            title: draft.title,
            payload: [
                "username": draft.username,
                "host": draft.host,
                "publicKey": draft.publicKey,
                "privateKeyReference": draft.privateKeyReference,
                "passphraseHint": draft.passphraseHint,
                "notes": draft.notes
            ]
        )
        return try LocalSshKeyEntry(entry)
    }

    public func setSshKeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSshKeyEntry {
        try LocalSshKeyEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "ssh-key", kind: "ssh-key", favorite: favorite))
    }

    public func deleteSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "ssh-key", kind: "ssh-key")
    }

    public func listDeletedSshKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSshKeyEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "ssh-key", kind: "ssh-key").map(LocalSshKeyEntry.init)
    }

    public func restoreSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSshKeyEntry {
        try LocalSshKeyEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "ssh-key", kind: "ssh-key"))
    }

    public func createApiTokenEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "api-token",
            kind: "api-token",
            title: draft.title,
            payload: [
                "issuer": draft.issuer,
                "accountName": draft.accountName,
                "token": draft.token,
                "scopes": draft.scopes,
                "expiresAt": draft.expiresAt,
                "notes": draft.notes
            ]
        )
        return try LocalApiTokenEntry(entry)
    }

    public func listApiTokenEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalApiTokenEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "api-token", kind: "api-token").map(LocalApiTokenEntry.init)
    }

    public func updateApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "api-token",
            kind: "api-token",
            title: draft.title,
            payload: [
                "issuer": draft.issuer,
                "accountName": draft.accountName,
                "token": draft.token,
                "scopes": draft.scopes,
                "expiresAt": draft.expiresAt,
                "notes": draft.notes
            ]
        )
        return try LocalApiTokenEntry(entry)
    }

    public func setApiTokenEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalApiTokenEntry {
        try LocalApiTokenEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "api-token", kind: "api-token", favorite: favorite))
    }

    public func deleteApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "api-token", kind: "api-token")
    }

    public func listDeletedApiTokenEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalApiTokenEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "api-token", kind: "api-token").map(LocalApiTokenEntry.init)
    }

    public func restoreApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalApiTokenEntry {
        try LocalApiTokenEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "api-token", kind: "api-token"))
    }

    public func createWifiEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "wifi",
            title: draft.title,
            payload: [
                "ssid": draft.ssid,
                "securityType": draft.securityType,
                "password": draft.password,
                "hidden": draft.hidden,
                "notes": draft.notes
            ]
        )
        return try LocalWifiEntry(entry)
    }

    public func listWifiEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalWifiEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "wifi").map(LocalWifiEntry.init)
    }

    public func updateWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "wifi",
            title: draft.title,
            payload: [
                "ssid": draft.ssid,
                "securityType": draft.securityType,
                "password": draft.password,
                "hidden": draft.hidden,
                "notes": draft.notes
            ]
        )
        return try LocalWifiEntry(entry)
    }

    public func setWifiEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalWifiEntry {
        try LocalWifiEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "wifi", favorite: favorite))
    }

    public func deleteWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "wifi")
    }

    public func listDeletedWifiEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalWifiEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "wifi").map(LocalWifiEntry.init)
    }

    public func restoreWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalWifiEntry {
        try LocalWifiEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "wifi"))
    }

    public func createSendEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "send",
            title: draft.title,
            payload: [
                "body": draft.body,
                "expiresAt": draft.expiresAt,
                "maxViews": draft.maxViews,
                "notes": draft.notes
            ]
        )
        return try LocalSendEntry(entry)
    }

    public func listSendEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSendEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "send").map(LocalSendEntry.init)
    }

    public func updateSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "send",
            title: draft.title,
            payload: [
                "body": draft.body,
                "expiresAt": draft.expiresAt,
                "maxViews": draft.maxViews,
                "notes": draft.notes
            ]
        )
        return try LocalSendEntry(entry)
    }

    public func setSendEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSendEntry {
        try LocalSendEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "send", favorite: favorite))
    }

    public func deleteSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "send")
    }

    public func listDeletedSendEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSendEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "send").map(LocalSendEntry.init)
    }

    public func restoreSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSendEntry {
        try LocalSendEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "send"))
    }

    public func createAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String = "",
        downloadState: String = "",
        wrappedContentEncryptionKey: String? = nil,
        localPath: String? = nil
    ) throws -> LocalAttachmentMetadata {
        var payload: [String: Any] = [
            "fileName": fileName,
            "mediaType": mediaType,
            "originalSize": originalSize,
            "storedSize": storedSize,
            "contentHash": contentHash,
            "storageMode": storageMode,
            "source": source,
            "downloadState": downloadState
        ]
        if let entryID {
            payload["entryID"] = entryID
        }
        if let wrappedContentEncryptionKey {
            payload["wrappedContentEncryptionKey"] = wrappedContentEncryptionKey
        }
        if let localPath {
            payload["localPath"] = localPath
        }
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "attachment-ref",
            title: fileName,
            payload: payload
        )
        return try LocalAttachmentMetadata(entry, deleted: false)
    }

    public func listAttachmentMetadata(in handle: LocalVaultHandle, projectID: String) throws -> [LocalAttachmentMetadata] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "attachment-ref")
            .map { try LocalAttachmentMetadata($0, deleted: false) }
    }

    public func updateAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String = "",
        downloadState: String = "",
        wrappedContentEncryptionKey: String? = nil,
        localPath: String? = nil
    ) throws -> LocalAttachmentMetadata {
        var payload: [String: Any] = [
            "fileName": fileName,
            "mediaType": mediaType,
            "originalSize": originalSize,
            "storedSize": storedSize,
            "contentHash": contentHash,
            "storageMode": storageMode,
            "source": source,
            "downloadState": downloadState
        ]
        if let entryID {
            payload["entryID"] = entryID
        }
        if let wrappedContentEncryptionKey {
            payload["wrappedContentEncryptionKey"] = wrappedContentEncryptionKey
        }
        if let localPath {
            payload["localPath"] = localPath
        }
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: attachmentID,
            entryType: "document-ref",
            kind: "attachment-ref",
            title: fileName,
            payload: payload
        )
        return try LocalAttachmentMetadata(entry, deleted: false)
    }

    public func deleteAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String) throws {
        try deleteParityEntry(
            in: handle,
            projectID: projectID,
            entryID: attachmentID,
            entryType: "document-ref",
            kind: "attachment-ref"
        )
    }

    public func listDeletedAttachmentMetadata(in handle: LocalVaultHandle, projectID: String) throws -> [LocalAttachmentMetadata] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "attachment-ref")
            .map { try LocalAttachmentMetadata($0, deleted: true) }
    }

    public func restoreAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String) throws -> LocalAttachmentMetadata {
        let entry = try restoreParityEntry(
            in: handle,
            projectID: projectID,
            entryID: attachmentID,
            entryType: "document-ref",
            kind: "attachment-ref"
        )
        return try LocalAttachmentMetadata(entry, deleted: false)
    }

    private func store(_ vault: MonicaMDBXVault, vaultID: String) {
        lock.lock()
        defer { lock.unlock() }
        vaults[vaultID] = vault
        projects[vaultID, default: []] = projects[vaultID, default: []]
    }

    private func vault(for handle: LocalVaultHandle) throws -> MonicaMDBXVault {
        lock.lock()
        defer { lock.unlock() }
        guard let vault = vaults[handle.vaultID] else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        return vault
    }

    private func projectContainsEntries(handle: LocalVaultHandle, projectID: String) throws -> Bool {
        try !listLoginEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedLoginEntries(in: handle, projectID: projectID).isEmpty
            || !listNoteEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedNoteEntries(in: handle, projectID: projectID).isEmpty
            || !listTotpEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedTotpEntries(in: handle, projectID: projectID).isEmpty
            || !listCardEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedCardEntries(in: handle, projectID: projectID).isEmpty
            || !listIdentityEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedIdentityEntries(in: handle, projectID: projectID).isEmpty
            || !listPasskeyEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedPasskeyEntries(in: handle, projectID: projectID).isEmpty
            || !listSshKeyEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedSshKeyEntries(in: handle, projectID: projectID).isEmpty
            || !listApiTokenEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedApiTokenEntries(in: handle, projectID: projectID).isEmpty
            || !listWifiEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedWifiEntries(in: handle, projectID: projectID).isEmpty
            || !listSendEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedSendEntries(in: handle, projectID: projectID).isEmpty
            || !listAttachmentMetadata(in: handle, projectID: projectID).isEmpty
            || !listDeletedAttachmentMetadata(in: handle, projectID: projectID).isEmpty
    }

    private func createParityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryType: String,
        kind: String,
        title: String,
        payload: [String: Any]
    ) throws -> MonicaMDBXParityEntry {
        try vault(for: handle).createParityEntry(
            projectID: projectID,
            entryType: entryType,
            kind: kind,
            title: title,
            payloadJSON: parityPayloadJSON(payload)
        )
    }

    private func listParityEntries(
        in handle: LocalVaultHandle,
        projectID: String,
        entryType: String,
        kind: String
    ) throws -> [MonicaMDBXParityEntry] {
        try vault(for: handle).listParityEntries(projectID: projectID, entryType: entryType, kind: kind)
    }

    private func listDeletedParityEntries(
        in handle: LocalVaultHandle,
        projectID: String,
        entryType: String,
        kind: String
    ) throws -> [MonicaMDBXParityEntry] {
        try vault(for: handle).listDeletedParityEntries(projectID: projectID, entryType: entryType, kind: kind)
    }

    private func updateParityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String,
        title: String,
        payload: [String: Any]
    ) throws -> MonicaMDBXParityEntry {
        try vault(for: handle).updateParityEntry(
            projectID: projectID,
            entryID: entryID,
            entryType: entryType,
            kind: kind,
            title: title,
            payloadJSON: parityPayloadJSON(payload)
        )
    }

    private func setParityEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String,
        favorite: Bool
    ) throws -> MonicaMDBXParityEntry {
        try vault(for: handle).setParityEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            entryType: entryType,
            kind: kind,
            favorite: favorite
        )
    }

    private func deleteParityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String
    ) throws {
        try vault(for: handle).deleteParityEntry(
            projectID: projectID,
            entryID: entryID,
            entryType: entryType,
            kind: kind
        )
    }

    private func restoreParityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String
    ) throws -> MonicaMDBXParityEntry {
        try vault(for: handle).restoreParityEntry(
            projectID: projectID,
            entryID: entryID,
            entryType: entryType,
            kind: kind
        )
    }

    private func moveParityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String,
        targetProjectID: String
    ) throws -> MonicaMDBXParityEntry {
        try vault(for: handle).moveParityEntry(
            projectID: projectID,
            entryID: entryID,
            entryType: entryType,
            kind: kind,
            targetProjectID: targetProjectID
        )
    }

    private func parityMoveMapping(for kind: UnifiedVaultItemKind) -> (entryType: String, kind: String) {
        switch kind {
        case .passkey:
            return ("passkey", "passkey")
        case .sshKey:
            return ("ssh-key", "ssh-key")
        case .apiToken:
            return ("api-token", "api-token")
        case .wifi:
            return ("document-ref", "wifi")
        case .send:
            return ("document-ref", "send")
        case .attachmentRef:
            return ("document-ref", "attachment-ref")
        case .login, .totp, .note, .card, .identity:
            preconditionFailure("Core entry kinds do not use parity move mapping.")
        }
    }

    private func parityPayloadJSON(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        return json
    }
}

private extension LocalLoginEntry {
    init(_ entry: MonicaMDBXLoginEntry) {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            username: entry.username,
            password: entry.password,
            url: entry.url,
            notes: entry.notes,
            favorite: entry.favorite
        )
    }
}

private extension LocalNoteEntry {
    init(_ entry: MonicaMDBXNoteEntry) {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            body: entry.body,
            favorite: entry.favorite
        )
    }
}

private extension LocalTotpEntry {
    init(_ entry: MonicaMDBXTotpEntry) {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            secret: entry.secret,
            issuer: entry.issuer,
            accountName: entry.accountName,
            period: entry.period,
            digits: entry.digits,
            algorithm: entry.algorithm,
            otpType: entry.otpType,
            counter: entry.counter,
            favorite: entry.favorite
        )
    }
}

private extension LocalCardEntry {
    init(_ entry: MonicaMDBXCardEntry) {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            cardholderName: entry.cardholderName,
            number: entry.number,
            expiryMonth: entry.expiryMonth,
            expiryYear: entry.expiryYear,
            cvv: entry.cvv,
            issuer: entry.issuer,
            network: entry.network,
            notes: entry.notes,
            favorite: entry.favorite
        )
    }
}

private extension LocalIdentityEntry {
    init(_ entry: MonicaMDBXIdentityEntry) {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            documentType: entry.documentType,
            fullName: entry.fullName,
            documentNumber: entry.documentNumber,
            issuer: entry.issuer,
            country: entry.country,
            issueDate: entry.issueDate,
            expiryDate: entry.expiryDate,
            notes: entry.notes,
            favorite: entry.favorite
        )
    }
}

private extension LocalPasskeyEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            relyingPartyID: payload.string("relyingPartyID"),
            username: payload.string("username"),
            userHandle: payload.string("userHandle"),
            credentialID: payload.string("credentialID"),
            publicKeyCOSE: payload.string("publicKeyCOSE"),
            privateKeyReference: payload.string("privateKeyReference"),
            notes: payload.string("notes"),
            favorite: entry.favorite
        )
    }
}

private extension LocalSshKeyEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            username: payload.string("username"),
            host: payload.string("host"),
            publicKey: payload.string("publicKey"),
            privateKeyReference: payload.string("privateKeyReference"),
            passphraseHint: payload.string("passphraseHint"),
            notes: payload.string("notes"),
            favorite: entry.favorite
        )
    }
}

private extension LocalApiTokenEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            issuer: payload.string("issuer"),
            accountName: payload.string("accountName"),
            token: payload.string("token"),
            scopes: payload.string("scopes"),
            expiresAt: payload.string("expiresAt"),
            notes: payload.string("notes"),
            favorite: entry.favorite
        )
    }
}

private extension LocalWifiEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            ssid: payload.string("ssid"),
            securityType: payload.string("securityType"),
            password: payload.string("password"),
            hidden: payload.bool("hidden"),
            notes: payload.string("notes"),
            favorite: entry.favorite
        )
    }
}

private extension LocalSendEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            body: payload.string("body"),
            expiresAt: payload.string("expiresAt"),
            maxViews: payload.int("maxViews"),
            notes: payload.string("notes"),
            favorite: entry.favorite
        )
    }
}

private extension LocalAttachmentMetadata {
    init(_ entry: MonicaMDBXParityEntry, deleted: Bool) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            entryID: payload.optionalString("entryID"),
            fileName: payload.string("fileName"),
            mediaType: payload.string("mediaType"),
            originalSize: payload.int64("originalSize"),
            storedSize: payload.int64("storedSize"),
            contentHash: payload.string("contentHash"),
            storageMode: payload.string("storageMode"),
            source: payload.string("source"),
            downloadState: payload.string("downloadState"),
            wrappedContentEncryptionKey: payload.optionalString("wrappedContentEncryptionKey"),
            localPath: payload.optionalString("localPath"),
            deleted: deleted
        )
    }
}

private extension MonicaMDBXParityEntry {
    func payloadDictionary() throws -> [String: Any] {
        guard let data = payloadJSON.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        return payload
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String {
        self[key] as? String ?? ""
    }

    func optionalString(_ key: String) -> String? {
        self[key] as? String
    }

    func bool(_ key: String) -> Bool {
        self[key] as? Bool ?? false
    }

    func int(_ key: String) -> Int {
        if let value = self[key] as? Int {
            return value
        }
        if let value = self[key] as? NSNumber {
            return value.intValue
        }
        return 0
    }

    func int64(_ key: String) -> Int64 {
        if let value = self[key] as? Int64 {
            return value
        }
        if let value = self[key] as? Int {
            return Int64(value)
        }
        if let value = self[key] as? NSNumber {
            return value.int64Value
        }
        return 0
    }
}
