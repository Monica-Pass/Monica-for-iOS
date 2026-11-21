import CryptoKit
import Foundation
import Security

// MARK: - 算法与结果

/// 生成器支持的 SSH 密钥算法（#154）。
///
/// 值与原 Android 实现 `SshKeyGenerator` 的 `ALGORITHM_*` 常量保持一致，
/// 方便 KDBX 往返时把 `MonicaSshAlgorithm` 原样带过去。
public enum SSHKeyAlgorithm: String, CaseIterable, Hashable, Sendable {
    case ed25519 = "ED25519"
    case rsa = "RSA"

    /// OpenSSH wire format 里的算法名，也就是公钥行的第一个字段。
    public var openSSHKeyType: String {
        switch self {
        case .ed25519: "ssh-ed25519"
        case .rsa: "ssh-rsa"
        }
    }

    public var displayName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .rsa: "RSA"
        }
    }
}

/// 一次生成的 SSH 密钥对（#154）。
///
/// `privateKeyOpenSSH` 只在生成后、写入 Keychain 之前短暂存在；
/// 条目里永远只保存公钥、指纹和 Keychain 引用。
public struct SSHKeyPair: Sendable, Equatable {
    /// 固定为 `OPENSSH`，与 Android 的 `FORMAT_OPENSSH` 对齐。
    public static let openSSHFormat = "OPENSSH"

    public var format: String {
        Self.openSSHFormat
    }

    public let algorithm: SSHKeyAlgorithm
    /// 实际位数：Ed25519 为 256，RSA 为 2048 / 3072 / 4096。
    public let keySize: Int
    /// 完整公钥行，形如 `ssh-ed25519 AAAA... user@example.com`。
    public let publicKeyOpenSSH: String
    /// OpenSSH PEM 私钥文本（`-----BEGIN OPENSSH PRIVATE KEY-----`）。
    public let privateKeyOpenSSH: String
    /// `SHA256:<base64 无 padding>`，与 `ssh-keygen -l` 输出一致。
    public let fingerprintSHA256: String
    public let comment: String

    public init(
        algorithm: SSHKeyAlgorithm,
        keySize: Int,
        publicKeyOpenSSH: String,
        privateKeyOpenSSH: String,
        fingerprintSHA256: String,
        comment: String
    ) {
        self.algorithm = algorithm
        self.keySize = keySize
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.privateKeyOpenSSH = privateKeyOpenSSH
        self.fingerprintSHA256 = fingerprintSHA256
        self.comment = comment
    }

    /// 展示用摘要（例如日志、调试器）。刻意不含私钥文本。
    public var publicSummary: String {
        "\(algorithm.displayName) \(keySize) · \(fingerprintSHA256)"
    }
}

extension SSHKeyPair: CustomStringConvertible, CustomDebugStringConvertible {
    /// 避免误把私钥打进日志：默认描述只有算法、位数和指纹。
    public var description: String {
        "SSHKeyPair(\(publicSummary))"
    }

    public var debugDescription: String {
        "SSHKeyPair(algorithm: \(algorithm.rawValue), keySize: \(keySize), "
            + "publicKey: \(publicKeyOpenSSH), fingerprint: \(fingerprintSHA256), privateKey: <redacted>)"
    }
}

public enum SSHKeyGenerationError: Error, Sendable, Equatable {
    /// RSA 只接受 2048 / 3072 / 4096，与 Android 的 `RSA_ALLOWED_KEY_SIZES` 一致。
    case unsupportedRSAKeySize(Int)
    /// `SecKeyCreateRandomKey` 失败，附带系统错误描述。
    case randomKeyGenerationFailed(String)
    /// 系统没有返回私钥的 DER 表示。
    case missingExternalRepresentation(String)
    /// `SecKeyCopyExternalRepresentation` 返回的不是可解析的 PKCS#1 RSAPrivateKey。
    case malformedPrivateKey
}

// MARK: - OpenSSH 编码

/// OpenSSH wire format 的纯编码工具（#154）。
///
/// 公钥 blob 的结构是「length-prefixed 算法名 + 算法相关字段」：
/// - Ed25519：`string "ssh-ed25519"` + `string 32 字节公钥`
/// - RSA：`string "ssh-rsa"` + `mpint e` + `mpint n`
public enum SSHOpenSSHEncoder {
    /// RFC 4251 §5 的 `string`：4 字节大端长度 + 内容。
    public static func string(_ data: Data) -> Data {
        var out = Data()
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }

    public static func string(_ value: String) -> Data {
        string(Data(value.utf8))
    }

    /// RFC 4251 §5 的 `mpint`：去掉前导零；最高位为 1 时补一个 `0x00`，避免被当成负数。
    public static func mpint(_ data: Data) -> Data {
        var bytes = Array(data)
        while bytes.count > 1, bytes[0] == 0 {
            bytes.removeFirst()
        }
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return string(Data(bytes))
    }

    public static func ed25519PublicKeyBlob(rawPublicKey: Data) -> Data {
        string(SSHKeyAlgorithm.ed25519.openSSHKeyType) + string(rawPublicKey)
    }

    public static func rsaPublicKeyBlob(modulus: Data, exponent: Data) -> Data {
        string(SSHKeyAlgorithm.rsa.openSSHKeyType) + mpint(exponent) + mpint(modulus)
    }

    /// 完整公钥行（含算法名）。
    public static func publicKeyLine(algorithm: SSHKeyAlgorithm, blob: Data, comment: String) -> String {
        let trimmed = sanitizedComment(comment)
        let base64 = blob.base64EncodedString()
        return trimmed.isEmpty
            ? "\(algorithm.openSSHKeyType) \(base64)"
            : "\(algorithm.openSSHKeyType) \(base64) \(trimmed)"
    }

    /// `SHA256:<base64 无 padding>`，与 `ssh-keygen -l -f` 的输出一致。
    public static func fingerprintSHA256(publicKeyBlob: Data) -> String {
        let digest = SHA256.hash(data: publicKeyBlob)
        let base64 = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(base64)"
    }

    /// OpenSSH 私钥文本（PEM，行宽 70，与 Android 一致）。
    ///
    /// 私钥本身不加密（cipher / kdf 都是 `none`）：它以 `WhenUnlockedThisDeviceOnly`
    /// 写入 Keychain，静态加密由 Keychain 负责，而不是再叠一层口令。
    public static func privateKeyPEM(
        keyType: String,
        publicKeyBlob: Data,
        privateFields: Data,
        comment: String
    ) -> String {
        let body = privateKeyBody(
            keyType: keyType,
            publicKeyBlob: publicKeyBlob,
            privateFields: privateFields,
            comment: comment
        )
        let base64 = base64Wrapped(body.base64EncodedString(), width: 70)
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(base64)\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    static func privateKeyBody(
        keyType: String,
        publicKeyBlob: Data,
        privateFields: Data,
        comment: String,
        checkInt: UInt32? = nil
    ) -> Data {
        let pair = checkInt ?? UInt32.random(in: 0...UInt32.max)
        var privateSection = Data()
        // checkint 是裸的 4 字节，不能再套一层 length prefix。
        privateSection += checkIntBytes(pair)
        privateSection += checkIntBytes(pair)
        privateSection += string(keyType)
        privateSection += privateFields
        privateSection += string(sanitizedComment(comment))
        var padding: UInt8 = 1
        while privateSection.count % 8 != 0 {
            privateSection.append(padding)
            padding += 1
        }

        var body = Data("openssh-key-v1\0".utf8)
        body += string("none")          // cipher
        body += string("none")          // kdf name
        body += string(Data())          // kdf options
        body += checkIntBytes(1)        // 公钥数量
        body += string(publicKeyBlob)
        body += string(privateSection)
        return body
    }

    static func sanitizedComment(_ comment: String) -> String {
        var value = comment
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count > 128 {
            value = String(value.prefix(128))
        }
        return value
    }

    static func base64Wrapped(_ base64: String, width: Int) -> String {
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: width, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return lines.joined(separator: "\n")
    }

    private static func checkIntBytes(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}

// MARK: - 生成器

/// SSH 密钥对生成（#154）。
///
/// Ed25519 走 CryptoKit `Curve25519.Signing`；RSA 走 Security 的 `SecKeyCreateRandomKey`，
/// 由系统负责素数生成，不允许手写素数。
public enum SSHKeyPairGenerator {
    /// 与 Android `RSA_ALLOWED_KEY_SIZES` 一致。
    public static let rsaKeySizeOptions = [2048, 3072, 4096]
    public static let defaultRSAKeySize = 3072
    public static let ed25519KeySize = 256

    /// 同步生成；RSA 4096 在低端设备上可能耗时数秒，调用方应放到后台任务里。
    public static func generate(
        algorithm: SSHKeyAlgorithm = .ed25519,
        rsaKeySize: Int = defaultRSAKeySize,
        comment: String = ""
    ) throws -> SSHKeyPair {
        switch algorithm {
        case .ed25519:
            return try generateEd25519(comment: comment)
        case .rsa:
            return try generateRSA(keySize: rsaKeySize, comment: comment)
        }
    }

    // MARK: Ed25519

    static func generateEd25519(comment: String) throws -> SSHKeyPair {
        let privateKey = Curve25519.Signing.PrivateKey()
        return try keyPair(privateKey: privateKey, comment: comment)
    }

    /// 由固定 seed 派生（RFC 8032 向量测试与将来导入私钥时使用）。
    static func keyPair(privateKey: Curve25519.Signing.PrivateKey, comment: String) throws -> SSHKeyPair {
        let rawPublicKey = privateKey.publicKey.rawRepresentation
        let publicBlob = SSHOpenSSHEncoder.ed25519PublicKeyBlob(rawPublicKey: rawPublicKey)
        let publicLine = SSHOpenSSHEncoder.publicKeyLine(
            algorithm: .ed25519,
            blob: publicBlob,
            comment: comment
        )

        // 私钥字段依次是：string 公钥、string（32 字节 seed || 32 字节公钥）。
        let privateFields = SSHOpenSSHEncoder.string(rawPublicKey)
            + SSHOpenSSHEncoder.string(privateKey.rawRepresentation + rawPublicKey)
        let pem = SSHOpenSSHEncoder.privateKeyPEM(
            keyType: SSHKeyAlgorithm.ed25519.openSSHKeyType,
            publicKeyBlob: publicBlob,
            privateFields: privateFields,
            comment: comment
        )

        return SSHKeyPair(
            algorithm: .ed25519,
            keySize: ed25519KeySize,
            publicKeyOpenSSH: publicLine,
            privateKeyOpenSSH: pem,
            fingerprintSHA256: SSHOpenSSHEncoder.fingerprintSHA256(publicKeyBlob: publicBlob),
            comment: SSHOpenSSHEncoder.sanitizedComment(comment)
        )
    }

    // MARK: RSA

    static func generateRSA(keySize: Int, comment: String) throws -> SSHKeyPair {
        guard rsaKeySizeOptions.contains(keySize) else {
            throw SSHKeyGenerationError.unsupportedRSAKeySize(keySize)
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: keySize,
            // 只放在内存里：私钥文本随后写入 Keychain，不能让 Security 框架再存一份。
            kSecAttrIsPermanent as String: false,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let message = error?.takeRetainedValue().localizedDescription
                ?? "SecKeyCreateRandomKey returned nil"
            throw SSHKeyGenerationError.randomKeyGenerationFailed(message)
        }
        guard let rawDER = SecKeyCopyExternalRepresentation(secKey, &error) else {
            let message = error?.takeRetainedValue().localizedDescription
                ?? "SecKeyCopyExternalRepresentation returned nil"
            throw SSHKeyGenerationError.missingExternalRepresentation(message)
        }
        let der = rawDER as Data

        let material: SSHRSAKeyMaterial
        do {
            material = try SSHRSAKeyMaterial(pkcs1DER: der)
        } catch {
            throw SSHKeyGenerationError.malformedPrivateKey
        }

        let publicBlob = SSHOpenSSHEncoder.rsaPublicKeyBlob(
            modulus: material.modulus,
            exponent: material.publicExponent
        )
        let publicLine = SSHOpenSSHEncoder.publicKeyLine(
            algorithm: .rsa,
            blob: publicBlob,
            comment: comment
        )

        // OpenSSH 的 ssh-rsa 私钥字段顺序：n, e, d, iqmp, p, q。
        let privateFields = SSHOpenSSHEncoder.mpint(material.modulus)
            + SSHOpenSSHEncoder.mpint(material.publicExponent)
            + SSHOpenSSHEncoder.mpint(material.privateExponent)
            + SSHOpenSSHEncoder.mpint(material.inverseQModP)
            + SSHOpenSSHEncoder.mpint(material.primeP)
            + SSHOpenSSHEncoder.mpint(material.primeQ)
        let pem = SSHOpenSSHEncoder.privateKeyPEM(
            keyType: SSHKeyAlgorithm.rsa.openSSHKeyType,
            publicKeyBlob: publicBlob,
            privateFields: privateFields,
            comment: comment
        )

        return SSHKeyPair(
            algorithm: .rsa,
            keySize: material.bitLength,
            publicKeyOpenSSH: publicLine,
            privateKeyOpenSSH: pem,
            fingerprintSHA256: SSHOpenSSHEncoder.fingerprintSHA256(publicKeyBlob: publicBlob),
            comment: SSHOpenSSHEncoder.sanitizedComment(comment)
        )
    }
}

// MARK: - PKCS#1 解析

struct SSHRSAKeyMaterial: Equatable {
    let modulus: Data
    let publicExponent: Data
    let privateExponent: Data
    let primeP: Data
    let primeQ: Data
    let inverseQModP: Data

    /// `SecKeyCopyExternalRepresentation` 对 RSA 私钥返回 PKCS#1 `RSAPrivateKey`：
    /// `SEQUENCE { INTEGER version, n, e, d, p, q, dP, dQ, qInv }`。
    init(pkcs1DER: Data) throws {
        var outer = SSHDERReader(data: pkcs1DER)
        let sequence = try outer.readSequence()
        var reader = SSHDERReader(data: sequence)
        let version = try reader.readInteger()
        guard version == Data([0]) else {
            throw SSHKeyGenerationError.malformedPrivateKey
        }
        modulus = try reader.readInteger().sshTrimmingLeadingZeros()
        publicExponent = try reader.readInteger().sshTrimmingLeadingZeros()
        privateExponent = try reader.readInteger().sshTrimmingLeadingZeros()
        primeP = try reader.readInteger().sshTrimmingLeadingZeros()
        primeQ = try reader.readInteger().sshTrimmingLeadingZeros()
        _ = try reader.readInteger()   // dP 不进入 OpenSSH 私钥
        _ = try reader.readInteger()   // dQ 不进入 OpenSSH 私钥
        inverseQModP = try reader.readInteger().sshTrimmingLeadingZeros()

        guard !modulus.isEmpty, !publicExponent.isEmpty, !privateExponent.isEmpty,
              !primeP.isEmpty, !primeQ.isEmpty, !inverseQModP.isEmpty
        else {
            throw SSHKeyGenerationError.malformedPrivateKey
        }
    }

    var bitLength: Int {
        let bytes = [UInt8](modulus)
        guard let first = bytes.first else { return 0 }
        return bytes.count * 8 - first.leadingZeroBitCount
    }
}

struct SSHDERReader {
    let data: Data
    private var index = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readInteger() throws -> Data {
        let (tag, value) = try readTLV()
        guard tag == 0x02 else {
            throw SSHKeyGenerationError.malformedPrivateKey
        }
        return value
    }

    mutating func readSequence() throws -> Data {
        let (tag, value) = try readTLV()
        guard tag == 0x30 else {
            throw SSHKeyGenerationError.malformedPrivateKey
        }
        return value
    }

    private mutating func readTLV() throws -> (tag: UInt8, value: Data) {
        guard index < data.count else {
            throw SSHKeyGenerationError.malformedPrivateKey
        }
        let tag = data[data.startIndex + index]
        index += 1
        guard index < data.count else {
            throw SSHKeyGenerationError.malformedPrivateKey
        }
        var length = Int(data[data.startIndex + index])
        index += 1
        if length & 0x80 != 0 {
            let byteCount = length & 0x7F
            guard byteCount > 0, byteCount <= 4, index + byteCount <= data.count else {
                throw SSHKeyGenerationError.malformedPrivateKey
            }
            length = 0
            for _ in 0..<byteCount {
                length = (length << 8) | Int(data[data.startIndex + index])
                index += 1
            }
        }
        guard index + length <= data.count else {
            throw SSHKeyGenerationError.malformedPrivateKey
        }
        let start = data.startIndex + index
        let value = data.subdata(in: start..<(start + length))
        index += length
        return (tag, value)
    }
}

extension Data {
    /// 去掉 DER INTEGER 为表示正数而补的前导 `0x00`。
    func sshTrimmingLeadingZeros() -> Data {
        var bytes = [UInt8](self)
        while bytes.count > 1, bytes[0] == 0 {
            bytes.removeFirst()
        }
        return Data(bytes)
    }
}
