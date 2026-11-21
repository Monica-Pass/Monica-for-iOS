// MARK: - KeePass（KDBX 解析 / 回写 / 格式检查与只读导入计划）

import Foundation
import CryptoKit
import MonicaStorageTwofish
import argon2
import zlib

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
            message: "当前无法加密该 KDBX 内容"
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
                message: "无法打开使用未知加密方式的 KDBX 文件"
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
                message: "无法写回使用未知加密方式的 KDBX 文件"
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
                message: "无法写回未知加密方式的 KDBX 文件头"
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
                message: "无法写回未知加密方式的 KDBX 文件头"
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
                message: "无法写回未知压缩方式的 KDBX 文件头"
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
                message: "无法写回未知密钥派生方式的 KDBX 文件头"
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
                message: "无法写回未知加密方式的 KDBX3 文件头"
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
                message: "无法写回未知加密方式的 KDBX3 文件头"
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
                message: "无法写回未知压缩方式的 KDBX3 文件头"
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
                message: "无法写回未知数据块格式的 KDBX 文件"
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
                message: "无法读取未知数据块格式的 KDBX 文件"
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
                message: "无法打开使用未知密钥派生方式的 KDBX 文件"
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
    public let originalGroupPath: String?
    public let originalGroupID: String?
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
        originalGroupPath: String? = nil,
        originalGroupID: String? = nil,
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
        let trimmedOriginalGroupPath = originalGroupPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedOriginalGroupID = originalGroupID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.originalGroupPath = trimmedOriginalGroupPath.isEmpty ? nil : trimmedOriginalGroupPath
        self.originalGroupID = trimmedOriginalGroupID.isEmpty ? nil : trimmedOriginalGroupID
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
        if entry.isDeleted, let originalGroupID = entry.originalGroupID {
            xml.append("\(indent)  <PreviousParentGroup>\(Self.escapeText(originalGroupID))</PreviousParentGroup>")
        }
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
            message: "当前无法解码该 KDBX 文件"
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

enum KeePassGzipPayloadInflator {
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
                message: "无法写回未知压缩方式的 KDBX3 文件"
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
                message: "无法写回未知压缩方式的 KDBX 文件"
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
            message: "当前无法解码该 KDBX 文件"
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

final class KeePassProtectedValueStreamDecoder {
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
                message: "无法读取未知保护流的 KeePass 数据"
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

final class KeePassProtectedValueStreamEncoder {
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
                message: "无法写回未知保护流的 KeePass 数据"
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
    var previousParentGroupUUID = ""
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
    private var historyDepth = 0
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
        case "History":
            historyDepth += 1
        case "Entry":
            // <History> 内的历史条目不是库里的可见条目；继续解析仅为推进保护值密钥流。
            if historyDepth == 0 {
                currentEntry = ParsedKeePassEntry()
            }
        case "String":
            // 历史条目也要读取 String：受保护值的密钥流按文档顺序推进，跳过会导致后续密码解码错位。
            if historyDepth > 0 || currentEntry != nil {
                currentString = ParsedKeePassStringField()
            }
        case "Binary":
            if currentEntry != nil && historyDepth == 0 {
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
            if historyDepth == 0, currentEntry != nil {
                currentEntry?.uuid = text
            } else if historyDepth == 0, !groupStack.isEmpty {
                groupStack[groupStack.count - 1].uuid = text
            }
        case "Name":
            if historyDepth == 0, currentEntry == nil, !groupStack.isEmpty {
                groupStack[groupStack.count - 1].name = text
            }
        case "RecycleBinUUID":
            parsed.recycleBinUUID = text.isEmpty ? nil : text
        case "PreviousParentGroup":
            if historyDepth == 0, currentEntry != nil {
                currentEntry?.previousParentGroupUUID = text
            }
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
            if historyDepth == 0, let field = currentString {
                currentEntry?.strings.append(field)
            }
            currentString = nil
        case "Binary":
            if historyDepth == 0, let binary = currentEntryBinary {
                currentEntry?.binaries.append(binary)
                currentEntryBinary = nil
            } else if let id = currentMetaBinaryID {
                parsed.binaries[id] = Data(base64Encoded: text) ?? Data()
                currentMetaBinaryID = nil
            }
        case "Entry":
            if historyDepth == 0, let entry = currentEntry, !groupStack.isEmpty {
                groupStack[groupStack.count - 1].entries.append(entry)
            }
            if historyDepth == 0 {
                currentEntry = nil
            }
        case "History":
            historyDepth = max(0, historyDepth - 1)
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
        let groupPathsByID = groupPathsByID(for: parsed.rootGroups)
        for root in parsed.rootGroups {
            append(
                group: root,
                parentComponents: [],
                isRootGroup: true,
                parentDeleted: false,
                parsed: parsed,
                groupPathsByID: groupPathsByID,
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
        groupPathsByID: [String: String],
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
                groupPathsByID: groupPathsByID,
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
                groupPathsByID: groupPathsByID,
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
        groupPathsByID: [String: String],
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
            originalGroupPath: isDeleted ? groupPathsByID[entry.previousParentGroupUUID] : nil,
            originalGroupID: isDeleted && !entry.previousParentGroupUUID.isEmpty ? entry.previousParentGroupUUID : nil,
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

    private static func groupPathsByID(for rootGroups: [ParsedKeePassGroup]) -> [String: String] {
        var paths: [String: String] = [:]
        for root in rootGroups {
            collectGroupPaths(
                group: root,
                parentComponents: [],
                isRootGroup: true,
                paths: &paths
            )
        }
        return paths
    }

    private static func collectGroupPaths(
        group: ParsedKeePassGroup,
        parentComponents: [String],
        isRootGroup: Bool,
        paths: inout [String: String]
    ) {
        let title = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = isRootGroup ? [] : parentComponents + [title.isEmpty ? "Untitled" : title]
        let path = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
        if !group.uuid.isEmpty {
            paths[group.uuid] = path
        }
        for child in group.groups {
            collectGroupPaths(
                group: child,
                parentComponents: components,
                isRootGroup: false,
                paths: &paths
            )
        }
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
