import CryptoKit
import Foundation

// MARK: - 元数据

/// OpenPGP（GPG）密钥条目的结构化元数据。
///
/// 这里只做 **ASCII armor 解码 + RFC 4880 / RFC 9580 packet 的结构化解析**：
/// 版本、算法、创建时间、过期时间、User ID、指纹与 key ID。
///
/// 明确的能力边界（与 issue #12 的验收要求一致）：
/// - 指纹计算是 OpenPGP 规范定义的哈希：v4 用 SHA-1（RFC 4880 §12.2 明文规定），
///   v6 用 SHA-256（RFC 9580 §5.5.4）。这里只计算与展示指纹，**不做任何签名验证**。
/// - `isRevoked` 只表示 armored 数据里出现了主密钥吊销签名 packet，
///   **不代表**该吊销已经过密码学验证；Monica 不做信任判定，也不维护信任网。
/// - 带口令私钥的口令校验、私钥解密、签名验证与加解密都需要完整的 OpenPGP 实现，
///   当前版本没有接入，因此这里**不解析、也不尝试解密私钥材料**。
///   私钥只能作为不透明的 armored 文本保存，供用户以后导出到别的工具里使用。
public struct GPGKeyMetadata: Sendable, Equatable {
    /// 密钥 packet 版本：4（RFC 4880）或 6（RFC 9580）。
    public let keyVersion: Int
    /// OpenPGP 公钥算法 ID（RFC 4880 §9.1）。
    public let algorithmID: UInt8
    /// 人类可读的算法名，例如 "RSA 4096"、"Ed25519"、"ECDSA P-256"。
    public let algorithm: String
    /// 大写十六进制指纹，v4 为 40 个字符，v6 为 64 个字符。
    public let fingerprint: String
    /// 大写十六进制 key ID，16 个字符。
    ///
    /// v4 取指纹最后 8 字节，v6 取指纹最前 8 字节——两者都是规范定义，不是截断猜测。
    public let keyID: String
    public let keyCreatedAt: Date
    /// 自签名里声明的过期时间；nil 表示「不声明过期」或数据里没有该子包。
    public let keyExpiresAt: Date?
    /// 主 User ID 的完整文本，例如 "Ada Lovelace (work) <ada@example.com>"。
    public let userID: String
    public let ownerName: String
    public let ownerEmail: String
    /// armored 数据里是否包含私钥 packet（tag 5）。
    public let isSecretKey: Bool
    /// 私钥材料是否受口令保护（S2K usage 字节非 0）。
    ///
    /// 注意：这里只读一个标志字节，**没有校验口令**，也无法判断口令是否正确。
    public let secretKeyIsEncrypted: Bool
    /// 是否出现主密钥吊销签名 packet（type 0x20）。未做签名验证。
    public let isRevoked: Bool

    public init(
        keyVersion: Int,
        algorithmID: UInt8,
        algorithm: String,
        fingerprint: String,
        keyID: String,
        keyCreatedAt: Date,
        keyExpiresAt: Date?,
        userID: String,
        ownerName: String,
        ownerEmail: String,
        isSecretKey: Bool,
        secretKeyIsEncrypted: Bool,
        isRevoked: Bool
    ) {
        self.keyVersion = keyVersion
        self.algorithmID = algorithmID
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.keyID = keyID
        self.keyCreatedAt = keyCreatedAt
        self.keyExpiresAt = keyExpiresAt
        self.userID = userID
        self.ownerName = ownerName
        self.ownerEmail = ownerEmail
        self.isSecretKey = isSecretKey
        self.secretKeyIsEncrypted = secretKeyIsEncrypted
        self.isRevoked = isRevoked
    }

    /// 每 4 个字符分组的指纹，便于人工核对。
    public var formattedFingerprint: String {
        GPGKeyMetadata.groupFingerprint(fingerprint)
    }

    public var isExpired: Bool {
        guard let keyExpiresAt else {
            return false
        }
        return keyExpiresAt < Date()
    }

    /// 把指纹按 4 字符分组；非十六进制或空串原样返回。
    public static func groupFingerprint(_ fingerprint: String) -> String {
        let trimmed = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else {
            return ""
        }
        var groups: [String] = []
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let end = trimmed.index(index, offsetBy: 4, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            groups.append(String(trimmed[index..<end]))
            index = end
        }
        return groups.joined(separator: " ")
    }
}

// MARK: - 错误

/// GPG 密钥导入的结构化校验错误。所有错误都可恢复：不写库、不留半成品。
public enum GPGKeyImportError: Error, Sendable, Equatable, LocalizedError {
    case emptyInput
    case missingArmorHeader
    case unsupportedArmorType(String)
    case missingArmorFooter
    case invalidBase64
    case armorChecksumMismatch
    case emptyKeyMaterial
    case malformedPacket(String)
    case unsupportedPartialBodyLength
    case unsupportedKeyVersion(Int)
    case unsupportedAlgorithm(Int)
    case noPrimaryKeyPacket
    case truncatedKeyMaterial
    case fingerprintMismatch(publicKey: String, privateKey: String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "请先粘贴 ASCII armored 的 GPG 公钥（可选再粘贴私钥）。"
        case .missingArmorHeader:
            return "没有找到 ASCII armor 头：需要以 -----BEGIN PGP PUBLIC KEY BLOCK----- 或 -----BEGIN PGP PRIVATE KEY BLOCK----- 开头。"
        case .unsupportedArmorType(let label):
            return "不支持的 ASCII armor 类型：\(label)。请粘贴公钥块或私钥块，不要粘贴签名或消息。"
        case .missingArmorFooter:
            return "ASCII armor 不完整：缺少对应的 -----END PGP ...----- 结束行。"
        case .invalidBase64:
            return "ASCII armor 内容不是合法的 Base64，可能复制时被截断或混入了多余字符。"
        case .armorChecksumMismatch:
            return "ASCII armor 校验和不匹配，数据可能在复制过程中被改动。"
        case .emptyKeyMaterial:
            return "ASCII armor 里没有密钥数据。"
        case .malformedPacket(let detail):
            return "OpenPGP packet 结构不合法：\(detail)"
        case .unsupportedPartialBodyLength:
            return "不支持带部分长度（partial body length）的 packet；请用 gpg --export 重新导出。"
        case .unsupportedKeyVersion(let version):
            return "暂不支持 OpenPGP 密钥版本 v\(version)；当前支持 v4 与 v6。"
        case .unsupportedAlgorithm(let id):
            return "暂不支持 OpenPGP 公钥算法 ID \(id)。"
        case .noPrimaryKeyPacket:
            return "数据里没有主密钥 packet（tag 5/6）。"
        case .truncatedKeyMaterial:
            return "密钥材料在 packet 结束前被截断。"
        case .fingerprintMismatch(let publicKey, let privateKey):
            return "公钥与私钥的指纹不一致：公钥 \(GPGKeyMetadata.groupFingerprint(publicKey))，私钥 \(GPGKeyMetadata.groupFingerprint(privateKey))。"
        }
    }
}

// MARK: - 解析器

/// 只做结构解析的 OpenPGP ASCII armor 解析器。
///
/// 不联网、不验证签名、不解密私钥、不做信任判定；纯函数，便于用固定向量测试。
public enum GPGKeyArmorParser {
    private enum ArmorKind {
        case publicKey
        case privateKey
    }

    /// 解析一段 ASCII armored 公钥（或私钥块）并返回结构化元数据。
    public static func parse(_ armored: String) throws -> GPGKeyMetadata {
        let trimmed = armored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GPGKeyImportError.emptyInput
        }
        let payload = try decodeArmor(trimmed)
        return try parsePackets(payload.bytes)
    }

    // MARK: ASCII armor

    private static func decodeArmor(_ armored: String) throws -> (bytes: [UInt8], kind: ArmorKind) {
        let normalized = armored
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard let beginIndex = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN PGP ") }) else {
            throw GPGKeyImportError.missingArmorHeader
        }

        let beginLine = lines[beginIndex]
        guard beginLine.hasSuffix("-----") else {
            throw GPGKeyImportError.missingArmorHeader
        }
        let label = beginLine
            .dropFirst("-----BEGIN PGP ".count)
            .dropLast(5)
        let kind: ArmorKind
        switch label {
        case "PUBLIC KEY BLOCK":
            kind = .publicKey
        case "PRIVATE KEY BLOCK":
            kind = .privateKey
        default:
            throw GPGKeyImportError.unsupportedArmorType(String(label))
        }

        let endLine = "-----END PGP \(label)-----"
        guard let endIndex = lines[(beginIndex + 1)...].firstIndex(of: endLine) else {
            throw GPGKeyImportError.missingArmorFooter
        }

        // armor 头（Version/Comment 等）以 "字段: 值" 出现，后跟一个空行；Base64 不含冒号。
        var bodyStart = beginIndex + 1
        while bodyStart < endIndex, lines[bodyStart].contains(": ") {
            bodyStart += 1
        }
        if bodyStart < endIndex, lines[bodyStart].isEmpty {
            bodyStart += 1
        }

        var base64 = ""
        var checksum: String?
        for index in bodyStart..<endIndex {
            let line = lines[index]
            if line.isEmpty {
                continue
            }
            if line.hasPrefix("="), line.count == 5 {
                checksum = String(line.dropFirst())
                continue
            }
            base64 += line
        }

        guard !base64.isEmpty else {
            throw GPGKeyImportError.emptyKeyMaterial
        }
        guard let data = Data(base64Encoded: base64) else {
            throw GPGKeyImportError.invalidBase64
        }

        let bytes = [UInt8](data)
        if let checksum {
            guard let crcData = Data(base64Encoded: checksum), crcData.count == 3 else {
                throw GPGKeyImportError.armorChecksumMismatch
            }
            let expected = (UInt32(crcData[crcData.startIndex]) << 16)
                | (UInt32(crcData[crcData.startIndex + 1]) << 8)
                | UInt32(crcData[crcData.startIndex + 2])
            guard crc24(bytes) == expected else {
                throw GPGKeyImportError.armorChecksumMismatch
            }
        }

        return (bytes, kind)
    }

    /// RFC 4880 §6.1 的 24 位 CRC，用于校验 armor 完整性（不是密码学签名）。
    static func crc24(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xB704CE
        for byte in bytes {
            crc ^= UInt32(byte) << 16
            for _ in 0..<8 {
                crc <<= 1
                if crc & 0x1000000 != 0 {
                    crc ^= 0x1864CFB
                }
            }
        }
        return crc & 0xFFFFFF
    }

    // MARK: packets

    private struct Packet {
        let tag: UInt8
        let body: [UInt8]
    }

    private static func parsePackets(_ bytes: [UInt8]) throws -> GPGKeyMetadata {
        var packets: [Packet] = []
        var offset = 0
        while offset < bytes.count {
            let header = bytes[offset]
            offset += 1
            guard header & 0x80 != 0 else {
                throw GPGKeyImportError.malformedPacket("packet 头缺少 bit 7")
            }

            let tag: UInt8
            var length = 0
            if header & 0x40 != 0 {
                // 新格式（RFC 4880 §4.2）
                tag = header & 0x3F
                guard offset < bytes.count else {
                    throw GPGKeyImportError.truncatedKeyMaterial
                }
                let first = Int(bytes[offset])
                offset += 1
                if first < 192 {
                    length = first
                } else if first < 224 {
                    guard offset < bytes.count else {
                        throw GPGKeyImportError.truncatedKeyMaterial
                    }
                    length = ((first - 192) << 8) + Int(bytes[offset]) + 192
                    offset += 1
                } else if first == 255 {
                    guard offset + 4 <= bytes.count else {
                        throw GPGKeyImportError.truncatedKeyMaterial
                    }
                    length = (Int(bytes[offset]) << 24)
                        | (Int(bytes[offset + 1]) << 16)
                        | (Int(bytes[offset + 2]) << 8)
                        | Int(bytes[offset + 3])
                    offset += 4
                } else {
                    // 224...254 是部分长度（流式包），密钥数据不应该使用。
                    throw GPGKeyImportError.unsupportedPartialBodyLength
                }
            } else {
                // 旧格式
                tag = (header >> 2) & 0x0F
                switch header & 0x03 {
                case 0:
                    guard offset < bytes.count else {
                        throw GPGKeyImportError.truncatedKeyMaterial
                    }
                    length = Int(bytes[offset])
                    offset += 1
                case 1:
                    guard offset + 2 <= bytes.count else {
                        throw GPGKeyImportError.truncatedKeyMaterial
                    }
                    length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
                    offset += 2
                case 2:
                    guard offset + 4 <= bytes.count else {
                        throw GPGKeyImportError.truncatedKeyMaterial
                    }
                    length = (Int(bytes[offset]) << 24)
                        | (Int(bytes[offset + 1]) << 16)
                        | (Int(bytes[offset + 2]) << 8)
                        | Int(bytes[offset + 3])
                    offset += 4
                default:
                    throw GPGKeyImportError.malformedPacket("不支持不定长旧格式 packet")
                }
            }

            guard length >= 0, offset + length <= bytes.count else {
                throw GPGKeyImportError.truncatedKeyMaterial
            }
            packets.append(Packet(tag: tag, body: Array(bytes[offset..<(offset + length)])))
            offset += length
        }

        guard let primaryIndex = packets.firstIndex(where: { $0.tag == 5 || $0.tag == 6 }) else {
            throw GPGKeyImportError.noPrimaryKeyPacket
        }

        var metadata = try parsePrimaryKey(packets[primaryIndex])
        var ownerName = ""
        var ownerEmail = ""
        var userID = ""
        var expiresAt: Date?

        for packet in packets[(primaryIndex + 1)...] {
            switch packet.tag {
            case 13: // User ID
                if userID.isEmpty, let text = String(bytes: packet.body, encoding: .utf8) {
                    userID = text
                    (ownerName, ownerEmail) = parseUserID(text)
                }
            case 2: // Signature
                let signature = try parseSignature(packet.body)
                if signature.isRevocation {
                    metadata = metadata.withRevoked(true)
                }
                if expiresAt == nil,
                   let seconds = signature.keyExpirationSeconds,
                   signature.isKeyCertification {
                    expiresAt = metadata.keyCreatedAt.addingTimeInterval(TimeInterval(seconds))
                }
            default:
                continue
            }
        }

        return GPGKeyMetadata(
            keyVersion: metadata.keyVersion,
            algorithmID: metadata.algorithmID,
            algorithm: metadata.algorithm,
            fingerprint: metadata.fingerprint,
            keyID: metadata.keyID,
            keyCreatedAt: metadata.keyCreatedAt,
            keyExpiresAt: expiresAt,
            userID: userID,
            ownerName: ownerName,
            ownerEmail: ownerEmail,
            isSecretKey: metadata.isSecretKey,
            secretKeyIsEncrypted: metadata.secretKeyIsEncrypted,
            isRevoked: metadata.isRevoked
        )
    }

    private static func parsePrimaryKey(_ packet: Packet) throws -> GPGKeyMetadata {
        var reader = ByteReader(bytes: packet.body)
        let version = Int(try reader.readUInt8())
        guard version == 4 || version == 6 else {
            throw GPGKeyImportError.unsupportedKeyVersion(version)
        }
        let createdAt = Date(timeIntervalSince1970: TimeInterval(try reader.readUInt32()))
        let algorithmID = try reader.readUInt8()

        let algorithm: String
        switch version {
        case 6:
            let declared = Int(try reader.readUInt32())
            guard declared > 0, reader.index + declared <= packet.body.count else {
                throw GPGKeyImportError.truncatedKeyMaterial
            }
            let material = Array(packet.body[reader.index..<(reader.index + declared)])
            var materialReader = ByteReader(bytes: material)
            (algorithm, _) = try parseKeyMaterial(id: algorithmID, reader: &materialReader)
            reader.advance(declared)
        default:
            (algorithm, _) = try parseKeyMaterial(id: algorithmID, reader: &reader)
        }

        // 私钥 packet 的指纹只对「公钥部分」计算，公钥部分到此为止。
        let publicPortion = Array(packet.body[0..<reader.index])
        guard !publicPortion.isEmpty else {
            throw GPGKeyImportError.truncatedKeyMaterial
        }

        let fingerprint: String
        let keyID: String
        switch version {
        case 6:
            var input = Data([0x9B])
            var length = UInt32(publicPortion.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(contentsOf: publicPortion)
            let digest = SHA256.hash(data: input)
            let hex = digest.map { String(format: "%02X", $0) }.joined()
            fingerprint = hex
            keyID = String(hex.prefix(16))
        default:
            var input = Data([0x99])
            input.append(UInt8((publicPortion.count >> 8) & 0xFF))
            input.append(UInt8(publicPortion.count & 0xFF))
            input.append(contentsOf: publicPortion)
            let digest = Insecure.SHA1.hash(data: input)
            let hex = digest.map { String(format: "%02X", $0) }.joined()
            fingerprint = hex
            keyID = String(hex.suffix(16))
        }

        // tag 5 的私钥材料紧跟在公钥部分之后：第一个字节是 S2K usage。
        // 0 表示未加密；254/255 表示用口令派生密钥加密。这里只记录标志，不解密、不校验口令。
        var secretKeyIsEncrypted = false
        if packet.tag == 5, reader.index < packet.body.count {
            secretKeyIsEncrypted = packet.body[reader.index] != 0
        }

        return GPGKeyMetadata(
            keyVersion: version,
            algorithmID: algorithmID,
            algorithm: algorithm,
            fingerprint: fingerprint,
            keyID: keyID,
            keyCreatedAt: createdAt,
            keyExpiresAt: nil,
            userID: "",
            ownerName: "",
            ownerEmail: "",
            isSecretKey: packet.tag == 5,
            secretKeyIsEncrypted: secretKeyIsEncrypted,
            isRevoked: false
        )
    }

    private struct ParsedSignature {
        let isRevocation: Bool
        /// 0x13（User ID 认证签名）或 0x1F（direct key 签名）才带主密钥过期子包。
        let isKeyCertification: Bool
        let keyExpirationSeconds: TimeInterval?
    }

    private static func parseSignature(_ body: [UInt8]) throws -> ParsedSignature {
        guard body.count >= 6, body[0] == 4 else {
            return ParsedSignature(isRevocation: false, isKeyCertification: false, keyExpirationSeconds: nil)
        }
        let signatureType = body[1]
        let hashedLength = (Int(body[4]) << 8) | Int(body[5])
        let hashedStart = 6
        let hashedEnd = min(hashedStart + hashedLength, body.count)

        var expiration: TimeInterval?
        var cursor = hashedStart
        while cursor < hashedEnd {
            let first = Int(body[cursor])
            var headerLength = 1
            var subpacketLength = 0
            if first < 192 {
                subpacketLength = first
            } else if first < 255 {
                guard cursor + 1 < hashedEnd else { break }
                subpacketLength = ((first - 192) << 8) + Int(body[cursor + 1]) + 192
                headerLength = 2
            } else {
                guard cursor + 4 < hashedEnd else { break }
                subpacketLength = (Int(body[cursor + 1]) << 24)
                    | (Int(body[cursor + 2]) << 16)
                    | (Int(body[cursor + 3]) << 8)
                    | Int(body[cursor + 4])
                headerLength = 5
            }
            guard subpacketLength >= 1 else { break }
            let subpacketStart = cursor + headerLength
            guard subpacketStart + subpacketLength <= hashedEnd else { break }
            let type = body[subpacketStart] & 0x7F
            let dataStart = subpacketStart + 1
            let dataLength = subpacketLength - 1
            // 子包 9 = key expiration time（自密钥创建时间起的秒数）。
            if type == 9, dataLength == 4, expiration == nil {
                let seconds = (UInt32(body[dataStart]) << 24)
                    | (UInt32(body[dataStart + 1]) << 16)
                    | (UInt32(body[dataStart + 2]) << 8)
                    | UInt32(body[dataStart + 3])
                if seconds > 0 {
                    expiration = TimeInterval(seconds)
                }
            }
            cursor = subpacketStart + subpacketLength
        }

        // 0x20 是主密钥吊销签名；0x28 是子密钥吊销，不能据此判定主密钥已吊销。
        let isRevocation = signatureType == 0x20
        let isKeyCertification = signatureType == 0x13 || signatureType == 0x1F
        return ParsedSignature(
            isRevocation: isRevocation,
            isKeyCertification: isKeyCertification,
            keyExpirationSeconds: expiration
        )
    }

    private static func parseUserID(_ text: String) -> (name: String, email: String) {
        guard let emailStart = text.lastIndex(of: "<"),
              let emailEnd = text.lastIndex(of: ">"),
              emailStart < emailEnd
        else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        let email = String(text[text.index(after: emailStart)..<emailEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var name = String(text[text.startIndex..<emailStart])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉 OpenPGP 惯例里的注释，例如 "Ada Lovelace (work)"。
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            name = String(name[name.startIndex..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (name, email)
    }

    // MARK: 算法材料

    private static func parseKeyMaterial(
        id: UInt8,
        reader: inout ByteReader
    ) throws -> (description: String, consumed: Int) {
        let start = reader.index
        let description: String
        switch id {
        case 1, 2, 3:
            // RSA：模数 n 与公钥指数 e 两个 MPI；n 的位长就是常说的密钥长度。
            let bits = try reader.readMPIBitLength()
            _ = try reader.readMPIBitLength()
            description = "RSA \(bits)"
        case 16, 20:
            let bits = try reader.readMPIBitLength()
            _ = try reader.readMPIBitLength()
            _ = try reader.readMPIBitLength()
            description = "Elgamal \(bits)"
        case 17:
            let bits = try reader.readMPIBitLength()
            _ = try reader.readMPIBitLength()
            _ = try reader.readMPIBitLength()
            _ = try reader.readMPIBitLength()
            description = "DSA \(bits)"
        case 18:
            let curve = try reader.readCurveOID()
            _ = try reader.readMPIBitLength()
            try reader.skipLengthPrefixedField()
            description = "ECDH \(curve)"
        case 19:
            let curve = try reader.readCurveOID()
            _ = try reader.readMPIBitLength()
            description = "ECDSA \(curve)"
        case 22:
            let curve = try reader.readCurveOID()
            _ = try reader.readMPIBitLength()
            // GnuPG 的传统 EdDSA 条目本身就指明曲线，避免出现「EdDSA Ed25519」这种重复。
            description = (curve == "Ed25519" || curve == "Ed448") ? curve : "EdDSA \(curve)"
        case 25:
            try reader.skipBytes(32)
            description = "X25519"
        case 26:
            try reader.skipBytes(56)
            description = "X448"
        case 27:
            try reader.skipBytes(32)
            description = "Ed25519"
        case 28:
            try reader.skipBytes(57)
            description = "Ed448"
        default:
            throw GPGKeyImportError.unsupportedAlgorithm(Int(id))
        }
        return (description, reader.index - start)
    }
}

// MARK: - 字节读取

private struct ByteReader {
    let bytes: [UInt8]
    private(set) var index: Int

    init(bytes: [UInt8], index: Int = 0) {
        self.bytes = bytes
        self.index = index
    }

    mutating func advance(_ count: Int) {
        index += count
    }

    mutating func readUInt8() throws -> UInt8 {
        guard index < bytes.count else {
            throw GPGKeyImportError.truncatedKeyMaterial
        }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func readUInt16() throws -> UInt16 {
        guard index + 2 <= bytes.count else {
            throw GPGKeyImportError.truncatedKeyMaterial
        }
        defer { index += 2 }
        return (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
    }

    mutating func readUInt32() throws -> UInt32 {
        guard index + 4 <= bytes.count else {
            throw GPGKeyImportError.truncatedKeyMaterial
        }
        defer { index += 4 }
        return (UInt32(bytes[index]) << 24)
            | (UInt32(bytes[index + 1]) << 16)
            | (UInt32(bytes[index + 2]) << 8)
            | UInt32(bytes[index + 3])
    }

    mutating func skipBytes(_ count: Int) throws {
        guard count >= 0, index + count <= bytes.count else {
            throw GPGKeyImportError.truncatedKeyMaterial
        }
        index += count
    }

    /// 读取 MPI 头里的位长并跳过数据，返回位长（RSA 的模数位长即密钥长度）。
    mutating func readMPIBitLength() throws -> Int {
        let bits = Int(try readUInt16())
        let byteCount = (bits + 7) / 8
        try skipBytes(byteCount)
        return bits
    }

    mutating func readCurveOID() throws -> String {
        let length = Int(try readUInt8())
        guard length > 0 else {
            throw GPGKeyImportError.malformedPacket("曲线 OID 长度为空")
        }
        guard index + length <= bytes.count else {
            throw GPGKeyImportError.truncatedKeyMaterial
        }
        let oid = Array(bytes[index..<(index + length)])
        index += length
        return GPGCurveOID.name(for: oid)
    }

    mutating func skipLengthPrefixedField() throws {
        let length = Int(try readUInt8())
        try skipBytes(length)
    }
}

// MARK: - 曲线 OID

private enum GPGCurveOID {
    private static let names: [[UInt8]: String] = [
        [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]: "P-256",
        [0x2B, 0x81, 0x04, 0x00, 0x22]: "P-384",
        [0x2B, 0x81, 0x04, 0x00, 0x23]: "P-521",
        [0x2B, 0x65, 0x6E]: "X25519",
        [0x2B, 0x65, 0x6F]: "X448",
        [0x2B, 0x65, 0x70]: "Ed25519",
        [0x2B, 0x65, 0x71]: "Ed448",
        [0x2B, 0x06, 0x01, 0x04, 0x01, 0x97, 0x55, 0x01, 0x05, 0x01]: "Ed25519",
        // GnuPG 传统 EdDSA（算法 22）使用的 OID：1.3.6.1.4.1.11591.15.1
        [0x2B, 0x06, 0x01, 0x04, 0x01, 0xDA, 0x47, 0x0F, 0x01]: "Ed25519",
        [0x2B, 0x24, 0x03, 0x03, 0x02, 0x08, 0x01, 0x01, 0x07]: "brainpoolP256r1",
        [0x2B, 0x24, 0x03, 0x03, 0x02, 0x08, 0x01, 0x01, 0x0B]: "brainpoolP384r1",
        [0x2B, 0x24, 0x03, 0x03, 0x02, 0x08, 0x01, 0x01, 0x0D]: "brainpoolP512r1"
    ]

    static func name(for oid: [UInt8]) -> String {
        if let name = names[oid] {
            return name
        }
        return "未知曲线"
    }
}

// MARK: - 元数据小工具

private extension GPGKeyMetadata {
    func withRevoked(_ revoked: Bool) -> GPGKeyMetadata {
        GPGKeyMetadata(
            keyVersion: keyVersion,
            algorithmID: algorithmID,
            algorithm: algorithm,
            fingerprint: fingerprint,
            keyID: keyID,
            keyCreatedAt: keyCreatedAt,
            keyExpiresAt: keyExpiresAt,
            userID: userID,
            ownerName: ownerName,
            ownerEmail: ownerEmail,
            isSecretKey: isSecretKey,
            secretKeyIsEncrypted: secretKeyIsEncrypted,
            isRevoked: revoked
        )
    }
}

// MARK: - 条目模型

/// 新建 / 编辑 GPG 密钥条目时的输入。
///
/// 刻意要求调用方先解析出 `metadata` 再构造 draft：解析失败就没有 draft，
/// 也就不会写入只有标题、没有指纹的「半成品」条目。
public struct LocalGPGKeyEntryDraft: Sendable, Equatable {
    public let title: String
    public let notes: String
    public let armoredPublicKey: String
    public let armoredPrivateKey: String
    public let metadata: GPGKeyMetadata
    /// 导入时间。`MonicaMDBXParityEntry` 本身没有创建时间字段，因此存进 payload。
    public let importedAt: Date

    public init(
        title: String,
        notes: String = "",
        armoredPublicKey: String,
        armoredPrivateKey: String = "",
        metadata: GPGKeyMetadata,
        importedAt: Date = Date()
    ) {
        self.title = title
        self.notes = notes
        self.armoredPublicKey = armoredPublicKey
        self.armoredPrivateKey = armoredPrivateKey
        self.metadata = metadata
        self.importedAt = importedAt
    }
}

/// 已落库的 GPG 密钥条目。
///
/// 指纹、key ID、算法、创建 / 过期时间都在导入时**一次性解析并固化**，
/// 之后读取条目不再重新跑 OpenPGP 解析，也不会尝试解密私钥。
public struct LocalGPGKeyEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let ownerName: String
    public let ownerEmail: String
    public let userID: String
    public let fingerprint: String
    public let keyID: String
    public let algorithm: String
    public let keyVersion: Int
    public let algorithmID: UInt8
    public let keyCreatedAt: Date
    public let keyExpiresAt: Date?
    public let isRevoked: Bool
    public let isSecretKey: Bool
    public let secretKeyIsEncrypted: Bool
    public let notes: String
    public let armoredPublicKey: String
    /// 只有在用户显式导入私钥块时才有值；始终是不透明的 armored 文本。
    public let armoredPrivateKey: String
    public let importedAt: Date
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        ownerName: String,
        ownerEmail: String,
        userID: String,
        fingerprint: String,
        keyID: String,
        algorithm: String,
        keyVersion: Int,
        algorithmID: UInt8,
        keyCreatedAt: Date,
        keyExpiresAt: Date?,
        isRevoked: Bool,
        isSecretKey: Bool,
        secretKeyIsEncrypted: Bool,
        notes: String,
        armoredPublicKey: String,
        armoredPrivateKey: String,
        importedAt: Date,
        favorite: Bool
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.ownerName = ownerName
        self.ownerEmail = ownerEmail
        self.userID = userID
        self.fingerprint = fingerprint
        self.keyID = keyID
        self.algorithm = algorithm
        self.keyVersion = keyVersion
        self.algorithmID = algorithmID
        self.keyCreatedAt = keyCreatedAt
        self.keyExpiresAt = keyExpiresAt
        self.isRevoked = isRevoked
        self.isSecretKey = isSecretKey
        self.secretKeyIsEncrypted = secretKeyIsEncrypted
        self.notes = notes
        self.armoredPublicKey = armoredPublicKey
        self.armoredPrivateKey = armoredPrivateKey
        self.importedAt = importedAt
        self.favorite = favorite
    }

    public var metadata: GPGKeyMetadata {
        GPGKeyMetadata(
            keyVersion: keyVersion,
            algorithmID: algorithmID,
            algorithm: algorithm,
            fingerprint: fingerprint,
            keyID: keyID,
            keyCreatedAt: keyCreatedAt,
            keyExpiresAt: keyExpiresAt,
            userID: userID,
            ownerName: ownerName,
            ownerEmail: ownerEmail,
            isSecretKey: isSecretKey,
            secretKeyIsEncrypted: secretKeyIsEncrypted,
            isRevoked: isRevoked
        )
    }

    public var formattedFingerprint: String {
        GPGKeyMetadata.groupFingerprint(fingerprint)
    }

    public var hasPrivateKey: Bool {
        !armoredPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isExpired: Bool {
        metadata.isExpired
    }

    /// 只描述「数据里写了什么」，不是信任判定：吊销签名未经密码学验证。
    public var statusSummary: String {
        if isRevoked {
            return "已吊销（未验证签名）"
        }
        if isExpired {
            return "已过期"
        }
        return "未过期"
    }

    var parityPayload: [String: Any] {
        GPGKeyPayload.dictionary(
            metadata: metadata,
            notes: notes,
            armoredPublicKey: armoredPublicKey,
            armoredPrivateKey: armoredPrivateKey,
            importedAt: importedAt
        )
    }
}

extension LocalGPGKeyEntryDraft {
    var parityPayload: [String: Any] {
        GPGKeyPayload.dictionary(
            metadata: metadata,
            notes: notes,
            armoredPublicKey: armoredPublicKey,
            armoredPrivateKey: armoredPrivateKey,
            importedAt: importedAt
        )
    }
}

/// payload 的键名与编解码集中在同一处，避免读写两侧漏字段。
enum GPGKeyPayload {
    static let userID = "userID"
    static let ownerName = "ownerName"
    static let ownerEmail = "ownerEmail"
    static let fingerprint = "fingerprint"
    static let keyID = "keyID"
    static let algorithm = "algorithm"
    static let keyVersion = "keyVersion"
    static let algorithmID = "algorithmID"
    static let keyCreatedAt = "keyCreatedAt"
    static let keyExpiresAt = "keyExpiresAt"
    static let isRevoked = "isRevoked"
    static let isSecretKey = "isSecretKey"
    static let secretKeyIsEncrypted = "secretKeyIsEncrypted"
    static let notes = "notes"
    static let armoredPublicKey = "armoredPublicKey"
    static let armoredPrivateKey = "armoredPrivateKey"
    static let importedAt = "importedAt"

    static func dictionary(
        metadata: GPGKeyMetadata,
        notes: String,
        armoredPublicKey: String,
        armoredPrivateKey: String,
        importedAt: Date
    ) -> [String: Any] {
        [
            Self.userID: metadata.userID,
            Self.ownerName: metadata.ownerName,
            Self.ownerEmail: metadata.ownerEmail,
            Self.fingerprint: metadata.fingerprint,
            Self.keyID: metadata.keyID,
            Self.algorithm: metadata.algorithm,
            Self.keyVersion: metadata.keyVersion,
            Self.algorithmID: Int(metadata.algorithmID),
            Self.keyCreatedAt: Int64(metadata.keyCreatedAt.timeIntervalSince1970),
            // 0 表示「没有过期时间」，因为 JSONSerialization 不接受 nil。
            Self.keyExpiresAt: Int64(metadata.keyExpiresAt?.timeIntervalSince1970 ?? 0),
            Self.isRevoked: metadata.isRevoked,
            Self.isSecretKey: metadata.isSecretKey,
            Self.secretKeyIsEncrypted: metadata.secretKeyIsEncrypted,
            Self.notes: notes,
            Self.armoredPublicKey: armoredPublicKey,
            Self.armoredPrivateKey: armoredPrivateKey,
            Self.importedAt: Int64(importedAt.timeIntervalSince1970)
        ]
    }
}
