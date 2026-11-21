import CryptoKit
import Foundation

// MARK: - XML 树

/// 保序的 XML 属性；写回时按原顺序输出，避免未知属性被重排或丢弃。
public struct KeePassXMLAttribute: Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// KeePass 文档的最小 XML 节点模型。
///
/// 这里刻意不做 schema 映射：解析时整棵树原样保留，编辑只改动被 touched 的节点，
/// 因此 `Times` / `AutoType` / `History` / 扩展节点等未知 XML 都会原样写回。
public struct KeePassXMLNode: Sendable, Equatable {
    public var name: String
    public var attributes: [KeePassXMLAttribute]
    public var children: [KeePassXMLNode]
    public var text: String?

    public init(
        name: String,
        attributes: [KeePassXMLAttribute] = [],
        children: [KeePassXMLNode] = [],
        text: String? = nil
    ) {
        self.name = name
        self.attributes = attributes
        self.children = children
        self.text = text
    }

    public func attribute(_ name: String) -> String? {
        attributes.first { $0.name == name }?.value
    }

    public func attributeIgnoringCase(_ name: String) -> String? {
        attributes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var isProtectedValue: Bool {
        guard name == "Value", let raw = attributeIgnoringCase("Protected") else {
            return false
        }
        return raw.caseInsensitiveCompare("true") == .orderedSame
    }

    public func firstChild(named name: String) -> KeePassXMLNode? {
        children.first { $0.name == name }
    }

    public func children(named name: String) -> [KeePassXMLNode] {
        children.filter { $0.name == name }
    }

    public var trimmedText: String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func setChildText(_ name: String, _ value: String) {
        if let index = children.firstIndex(where: { $0.name == name }) {
            children[index].text = value
        } else {
            children.append(KeePassXMLNode(name: name, text: value))
        }
    }

    public func containsElement(named name: String) -> Bool {
        if self.name == name {
            return true
        }
        return children.contains { $0.containsElement(named: name) }
    }

    func textValues(forElementNamed name: String) -> [String] {
        var values: [String] = []
        if self.name == name {
            values.append(text ?? "")
        }
        for child in children {
            values.append(contentsOf: child.textValues(forElementNamed: name))
        }
        return values
    }
}

// MARK: - 容器与视图模型

public enum KeePassNativeContainer: Sendable, Equatable {
    case kdbx3
    case kdbx4

    public var displayName: String {
        switch self {
        case .kdbx3:
            return "KDBX 3"
        case .kdbx4:
            return "KDBX 4"
        }
    }
}

/// 组树中的一层（按先序遍历展开，`depth` 用于缩进）。
public struct KeePassNativeGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let parentID: String?
    public let depth: Int
    public let path: String
    public let entryCount: Int
    public let childGroupCount: Int
    public let isRecycleBin: Bool
    public let isRoot: Bool

    public init(
        id: String,
        title: String,
        parentID: String?,
        depth: Int,
        path: String,
        entryCount: Int,
        childGroupCount: Int,
        isRecycleBin: Bool,
        isRoot: Bool
    ) {
        self.id = id
        self.title = title
        self.parentID = parentID
        self.depth = depth
        self.path = path
        self.entryCount = entryCount
        self.childGroupCount = childGroupCount
        self.isRecycleBin = isRecycleBin
        self.isRoot = isRoot
    }
}

/// 条目基础字段的只读投影；密码等明文字段仅驻留内存，写回时按原保护标记加密。
public struct KeePassNativeEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let groupID: String
    public let groupPath: String
    public let title: String
    public let username: String
    public let password: String
    public let url: String
    public let notes: String
    public let hasPasswordField: Bool
    public let isInRecycleBin: Bool
    public let protectedFieldKeys: [String]

    public init(
        id: String,
        groupID: String,
        groupPath: String,
        title: String,
        username: String,
        password: String,
        url: String,
        notes: String,
        hasPasswordField: Bool,
        isInRecycleBin: Bool,
        protectedFieldKeys: [String]
    ) {
        self.id = id
        self.groupID = groupID
        self.groupPath = groupPath
        self.title = title
        self.username = username
        self.password = password
        self.url = url
        self.notes = notes
        self.hasPasswordField = hasPasswordField
        self.isInRecycleBin = isInRecycleBin
        self.protectedFieldKeys = protectedFieldKeys
    }

    public var isEmptyPassword: Bool {
        password.isEmpty
    }

    public var displayTitle: String {
        title.isEmpty ? "(未命名条目)" : title
    }
}

public struct KeePassNativeWriteBackOutcome: Sendable, Equatable {
    public let databaseByteCount: Int
    public let groupCount: Int
    public let entryCount: Int

    public init(databaseByteCount: Int, groupCount: Int, entryCount: Int) {
        self.databaseByteCount = databaseByteCount
        self.groupCount = groupCount
        self.entryCount = entryCount
    }
}

// MARK: - 随机参数

public enum KeePassNativeCryptoRandom {
    public static func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            bytes.append(UInt8.random(in: 0...255, using: &generator))
        }
        return Data(bytes)
    }

    /// 为一次写回生成全新的 master seed / IV / inner stream key / start bytes。
    ///
    /// KDF 参数、cipher、压缩方式与 inner stream 算法保持原样；只替换随机量，
    /// 避免复用旧 IV 或旧 inner stream keystream。
    public static func makeInputs(
        container: KeePassNativeContainer,
        cipher: KeePassKdbxCipherAlgorithm,
        innerRandomStreamID: UInt32?
    ) throws -> KeePassKdbxPayloadCryptoInputs {
        let ivByteCount: Int
        switch cipher {
        case .aes256, .twofish:
            ivByteCount = 16
        case .chacha20:
            ivByteCount = 12
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "无法为未知 cipher 生成写回参数。"
            )
        }

        let innerKey: Data?
        switch innerRandomStreamID {
        case .some(2):
            innerKey = randomData(count: 32)
        case .some(3):
            innerKey = randomData(count: 64)
        case .some(0), .none:
            innerKey = nil
        case .some(let value):
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "无法为未知 inner stream(\(value)) 生成写回参数。"
            )
        }

        switch container {
        case .kdbx3:
            return KeePassKdbxPayloadCryptoInputs(
                masterSeed: randomData(count: 32),
                encryptionIV: randomData(count: ivByteCount),
                innerRandomStreamKey: innerKey,
                streamStartBytes: randomData(count: 32),
                innerRandomStreamID: innerRandomStreamID
            )
        case .kdbx4:
            return KeePassKdbxPayloadCryptoInputs(
                masterSeed: randomData(count: 32),
                encryptionIV: randomData(count: ivByteCount),
                innerRandomStreamKey: innerKey,
                streamStartBytes: nil,
                innerRandomStreamID: innerRandomStreamID
            )
        }
    }
}

// MARK: - KDBX 组装

/// 直接复用 MonicaStorage 已有的 header/cipher/HMAC 基元组装 KDBX 文件。
///
/// 与 `KeePassXMLPayloadWriter` 的区别：XML 由调用方提供，因此可以写回任意保序 XML
/// （包含未知节点、附件引用与原始保护标记），不会按 UI 可见字段重新造一份 XML。
public struct KeePassNativeKdbxWriter: Sendable {
    public struct InnerHeaderField: Sendable, Equatable {
        public let id: UInt8
        public let body: Data

        public init(id: UInt8, body: Data) {
            self.id = id
            self.body = body
        }
    }

    public init() {}

    public func writeDatabase(
        xmlData: Data,
        container: KeePassNativeContainer,
        cipher: KeePassKdbxCipherAlgorithm,
        compression: KeePassKdbxCompressionAlgorithm,
        kdfParameters: KeePassKdbxKdfParameters,
        credentials: KeePassUnlockCredentials,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs,
        binaries: [Data] = [],
        unknownInnerHeaderFields: [InnerHeaderField] = []
    ) throws -> Data {
        let candidate = try writebackCredentialCandidate(from: credentials)
        switch container {
        case .kdbx4:
            return try writeKdbx4(
                xmlData: xmlData,
                cipher: cipher,
                compression: compression,
                kdfParameters: kdfParameters,
                candidate: candidate,
                cryptoInputs: cryptoInputs,
                binaries: binaries,
                unknownInnerHeaderFields: unknownInnerHeaderFields
            )
        case .kdbx3:
            return try writeKdbx3(
                xmlData: xmlData,
                cipher: cipher,
                compression: compression,
                kdfParameters: kdfParameters,
                candidate: candidate,
                cryptoInputs: cryptoInputs
            )
        }
    }

    private func writeKdbx3(
        xmlData: Data,
        cipher: KeePassKdbxCipherAlgorithm,
        compression: KeePassKdbxCompressionAlgorithm,
        kdfParameters: KeePassKdbxKdfParameters,
        candidate: KeePassCredentialCandidate,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs
    ) throws -> Data {
        guard cryptoInputs.streamStartBytes?.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX3 写回缺少 32 字节 stream start bytes。"
            )
        }
        guard cryptoInputs.innerRandomStreamKey != nil,
              cryptoInputs.innerRandomStreamID != nil else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX3 写回缺少 inner stream 参数，源文件中的受保护字段无法重新加密。"
            )
        }
        let headerBytes = try DefaultKeePassKdbx3HeaderWriter().writeHeader(
            cipher: cipher,
            compression: compression,
            cryptoInputs: cryptoInputs,
            kdfParameters: kdfParameters
        )
        let payloadPlaintext = try compressedPayload(xmlData, compression: compression)
        let blockStream = try DefaultKeePassKdbxBlockStreamEncoder().encodeBlockStream(
            payloadPlaintext,
            context: KeePassKdbxBlockStreamContext(
                formatVersion: .kdbx3,
                streamStartBytes: cryptoInputs.streamStartBytes
            )
        )
        let context = try KeePassKdbxDecryptInputContext.build(
            database: headerBytes + Data("writeback-placeholder".utf8),
            sourceName: nil,
            credentialCandidate: candidate
        )
        let derivedKey = try DefaultKeePassKdbxKeyDeriver().deriveKey(from: context)
        let masterKey = try DefaultKeePassKdbxMasterKeyComposer().composeMasterKey(
            from: derivedKey,
            cryptoInputs: cryptoInputs
        )
        let encryptedPayload = try DefaultKeePassKdbxPayloadCipher().encryptPayload(
            blockStream,
            cipher: cipher,
            masterKey: masterKey,
            cryptoInputs: cryptoInputs
        )
        var database = Data()
        database.reserveCapacity(headerBytes.count + encryptedPayload.count)
        database.append(headerBytes)
        database.append(encryptedPayload)
        return database
    }

    private func writeKdbx4(
        xmlData: Data,
        cipher: KeePassKdbxCipherAlgorithm,
        compression: KeePassKdbxCompressionAlgorithm,
        kdfParameters: KeePassKdbxKdfParameters,
        candidate: KeePassCredentialCandidate,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs,
        binaries: [Data],
        unknownInnerHeaderFields: [InnerHeaderField]
    ) throws -> Data {
        guard let masterSeed = cryptoInputs.masterSeed, masterSeed.count == 32 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX4 写回缺少 32 字节 master seed。"
            )
        }
        guard let encryptionIV = cryptoInputs.encryptionIV else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX4 写回缺少加密 IV。"
            )
        }
        switch cipher {
        case .aes256, .twofish:
            guard encryptionIV.count == 16 else {
                throw KeePassOperationError(
                    code: .formatUnsupported,
                    message: "KDBX4 AES/Twofish 写回需要 16 字节 IV。"
                )
            }
        case .chacha20:
            guard encryptionIV.count == 12 else {
                throw KeePassOperationError(
                    code: .formatUnsupported,
                    message: "KDBX4 ChaCha20 写回需要 12 字节 IV。"
                )
            }
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "无法用未知 cipher 写回 KDBX4 文件。"
            )
        }

        // KDBX4 的 inner stream key / ID 属于 inner header，不能写进外层 header。
        let headerCryptoInputs = KeePassKdbxPayloadCryptoInputs(
            masterSeed: masterSeed,
            encryptionIV: encryptionIV
        )
        let headerBytes = try DefaultKeePassKdbx4HeaderWriter().writeHeader(
            cipher: cipher,
            compression: compression,
            cryptoInputs: headerCryptoInputs,
            kdfParameters: kdfParameters
        )
        let payloadPlaintext = try compressedPayload(xmlData, compression: compression)

        var innerHeader = Data()
        if let innerRandomStreamID = cryptoInputs.innerRandomStreamID {
            appendInnerHeaderField(id: 1, body: littleEndianUInt32(innerRandomStreamID), to: &innerHeader)
        }
        if let innerRandomStreamKey = cryptoInputs.innerRandomStreamKey {
            appendInnerHeaderField(id: 2, body: innerRandomStreamKey, to: &innerHeader)
        }
        for binary in binaries {
            appendInnerHeaderField(id: 3, body: Data([0x00]) + binary, to: &innerHeader)
        }
        for field in unknownInnerHeaderFields where field.id != 0 && field.id != 1 && field.id != 2 && field.id != 3 {
            appendInnerHeaderField(id: field.id, body: field.body, to: &innerHeader)
        }
        appendInnerHeaderField(id: 0, body: Data(), to: &innerHeader)

        var plaintext = Data()
        plaintext.reserveCapacity(innerHeader.count + payloadPlaintext.count)
        plaintext.append(innerHeader)
        plaintext.append(payloadPlaintext)

        let context = try KeePassKdbxDecryptInputContext.build(
            database: headerBytes + Data("writeback-placeholder".utf8),
            sourceName: nil,
            credentialCandidate: candidate
        )
        let derivedKey = try DefaultKeePassKdbxKeyDeriver().deriveKey(from: context)
        let masterKey = try DefaultKeePassKdbxMasterKeyComposer().composeMasterKey(
            from: derivedKey,
            cryptoInputs: cryptoInputs
        )
        let encryptedPayload = try DefaultKeePassKdbxPayloadCipher().encryptPayload(
            plaintext,
            cipher: cipher,
            masterKey: masterKey,
            cryptoInputs: cryptoInputs
        )
        let payloadSection = try DefaultKeePassKdbx4PayloadSectionWriter().writePayloadSection(
            encryptedPayloadBlocks: [encryptedPayload],
            headerBytes: headerBytes,
            masterSeed: masterSeed,
            derivedKey: derivedKey
        )
        return try DefaultKeePassKdbxFileAssembler().assemble(
            headerBytes: headerBytes,
            payloadSection: payloadSection
        )
    }

    private func compressedPayload(
        _ xmlData: Data,
        compression: KeePassKdbxCompressionAlgorithm
    ) throws -> Data {
        switch compression {
        case .none:
            return xmlData
        case .gzip:
            return try KeePassGzipPayloadCompressor().compress(xmlData)
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "无法写回未知压缩方式的 KDBX 文件。"
            )
        }
    }

    private func writebackCredentialCandidate(
        from credentials: KeePassUnlockCredentials
    ) throws -> KeePassCredentialCandidate {
        if let candidateLabel = credentials.candidateLabel,
           let candidate = credentials.credentialCandidates.first(where: { $0.label == candidateLabel }) {
            return candidate
        }
        guard let candidate = credentials.credentialCandidates.first else {
            throw KeePassOperationError(
                code: .invalidCredential,
                message: "KDBX 写回需要数据库密码或密钥文件。"
            )
        }
        return candidate
    }

    private func appendInnerHeaderField(id: UInt8, body: Data, to data: inout Data) {
        data.append(id)
        data.append(littleEndianUInt32(UInt32(body.count)))
        data.append(body)
    }

    private func littleEndianUInt32(_ value: UInt32) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }
}

// MARK: - XML 渲染

private enum KeePassNativeXMLRenderer {
    static func render(
        _ root: KeePassXMLNode,
        protectedEncoder: KeePassProtectedValueStreamEncoder?
    ) throws -> Data {
        var output = "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?>\n"
        try renderNode(root, depth: 0, protectedEncoder: protectedEncoder, into: &output)
        guard let data = output.data(using: .utf8) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KeePass XML 无法编码为 UTF-8。"
            )
        }
        return data
    }

    private static func renderNode(
        _ node: KeePassXMLNode,
        depth: Int,
        protectedEncoder: KeePassProtectedValueStreamEncoder?,
        into output: inout String
    ) throws {
        let indent = String(repeating: "\t", count: depth)
        output += indent
        output += "<" + node.name
        for attribute in node.attributes {
            output += " " + attribute.name + "=\"" + escapeAttribute(attribute.value) + "\""
        }

        let text = try resolvedText(node, protectedEncoder: protectedEncoder)

        if node.children.isEmpty {
            if text.isEmpty {
                output += " />\n"
            } else {
                output += ">" + escapeText(text) + "</" + node.name + ">\n"
            }
            return
        }

        output += ">\n"
        for child in node.children {
            try renderNode(child, depth: depth + 1, protectedEncoder: protectedEncoder, into: &output)
        }
        output += indent + "</" + node.name + ">\n"
    }

    private static func resolvedText(
        _ node: KeePassXMLNode,
        protectedEncoder: KeePassProtectedValueStreamEncoder?
    ) throws -> String {
        guard node.isProtectedValue else {
            return node.text ?? ""
        }
        guard let protectedEncoder else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "当前 KDBX 缺少 inner stream key，无法重新加密受保护字段。"
            )
        }
        return protectedEncoder.encode(node.text ?? "")
    }

    private static func escapeText(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        return escaped
    }

    private static func escapeAttribute(_ value: String) -> String {
        var escaped = escapeText(value)
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "\n", with: "&#10;")
        escaped = escaped.replacingOccurrences(of: "\r", with: "&#13;")
        escaped = escaped.replacingOccurrences(of: "\t", with: "&#9;")
        return escaped
    }
}

// MARK: - XML 解析

private final class KeePassNativeXMLTreeBuilder: NSObject, XMLParserDelegate {
    private(set) var rootNode: KeePassXMLNode?
    private(set) var parseError: Error?
    private var stack: [KeePassXMLNode] = []
    private var pendingText = ""
    private var protectedDecoder: KeePassProtectedValueStreamDecoder?
    private let decoderFactory: () throws -> KeePassProtectedValueStreamDecoder?

    init(decoderFactory: @escaping () throws -> KeePassProtectedValueStreamDecoder?) {
        self.decoderFactory = decoderFactory
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let attributes = attributeDict
            .map { KeePassXMLAttribute(name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }
        let node = KeePassXMLNode(name: elementName, attributes: attributes)

        if !pendingText.isEmpty {
            if !stack.isEmpty {
                stack[stack.count - 1].text = (stack[stack.count - 1].text ?? "") + pendingText
            }
            pendingText = ""
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        pendingText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            pendingText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard var node = stack.popLast() else {
            return
        }
        node.text = (node.text ?? "") + pendingText
        pendingText = ""

        if node.isProtectedValue {
            do {
                if protectedDecoder == nil {
                    protectedDecoder = try decoderFactory()
                }
                guard let protectedDecoder else {
                    throw KeePassOperationError(
                        code: .formatUnsupported,
                        message: "KDBX 受保护字段缺少 inner stream key，无法读取；请确认文件未损坏。"
                    )
                }
                node.text = try protectedDecoder.decode(node.text ?? "")
            } catch {
                parseError = error
                parser.abortParsing()
                return
            }
        }

        if stack.isEmpty {
            rootNode = node
        } else {
            stack[stack.count - 1].children.append(node)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if self.parseError == nil {
            self.parseError = parseError
        }
    }
}

// MARK: - KDBX4 inner header

private struct KeePassNativeInnerHeader {
    var innerRandomStreamID: UInt32?
    var innerRandomStreamKey: Data?
    var binaries: [Data]
    var unknownFields: [KeePassNativeKdbxWriter.InnerHeaderField]
    var payload: Data

    static func parse(_ decryptedPayload: Data) throws -> KeePassNativeInnerHeader {
        var offset = 0
        var innerRandomStreamID: UInt32?
        var innerRandomStreamKey: Data?
        var binaries: [Data] = []
        var unknownFields: [KeePassNativeKdbxWriter.InnerHeaderField] = []

        while offset + 5 <= decryptedPayload.count {
            let fieldID = decryptedPayload[decryptedPayload.startIndex + offset]
            let length = Int(readUInt32LE(decryptedPayload, at: offset + 1))
            let bodyStart = offset + 5
            guard length >= 0, bodyStart + length <= decryptedPayload.count else {
                throw KeePassOperationError(
                    code: .formatUnsupported,
                    message: "KDBX4 inner header 字段长度越界；请确认文件未损坏。"
                )
            }
            let body = decryptedPayload.subdata(in: (decryptedPayload.startIndex + bodyStart)..<(decryptedPayload.startIndex + bodyStart + length))
            offset = bodyStart + length

            switch fieldID {
            case 0:
                guard length == 0 else {
                    throw KeePassOperationError(
                        code: .formatUnsupported,
                        message: "KDBX4 inner header 结束字段长度无效；请确认文件未损坏。"
                    )
                }
                return KeePassNativeInnerHeader(
                    innerRandomStreamID: innerRandomStreamID,
                    innerRandomStreamKey: innerRandomStreamKey,
                    binaries: binaries,
                    unknownFields: unknownFields,
                    payload: decryptedPayload.subdata(in: (decryptedPayload.startIndex + offset)..<decryptedPayload.endIndex)
                )
            case 1:
                guard body.count == 4 else {
                    throw KeePassOperationError(
                        code: .formatUnsupported,
                        message: "KDBX4 inner header inner stream ID 无效；请确认文件未损坏。"
                    )
                }
                innerRandomStreamID = readUInt32LE(body, at: 0)
            case 2:
                innerRandomStreamKey = body
            case 3:
                guard body.count >= 1 else {
                    throw KeePassOperationError(
                        code: .formatUnsupported,
                        message: "KDBX4 inner header 附件字段为空；请确认文件未损坏。"
                    )
                }
                binaries.append(body.dropFirst())
            default:
                unknownFields.append(
                    KeePassNativeKdbxWriter.InnerHeaderField(id: fieldID, body: body)
                )
            }
        }

        throw KeePassOperationError(
            code: .formatUnsupported,
            message: "KDBX4 inner header 缺少结束字段；请确认文件未损坏。"
        )
    }
}

private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
    let start = data.startIndex + offset
    return UInt32(data[start])
        | (UInt32(data[start + 1]) << 8)
        | (UInt32(data[start + 2]) << 16)
        | (UInt32(data[start + 3]) << 24)
}

// MARK: - 时间戳

private enum KeePassNativeTimestamp {
    static func now() -> String {
        base64(for: Date())
    }

    /// KeePass 2.x 的 `<Times>` 使用 base64 编码的 .NET DateTime（自 0001-01-01 起的秒数，小端）。
    static func base64(for date: Date) -> String {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down)) + 62_135_596_800
        var littleEndian = seconds.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }.base64EncodedString()
    }
}

// MARK: - 文档

/// KeePass 原生库文档：保留完整 XML 与 KDBX 头部信息，支持组/条目编辑后原样写回。
///
/// 设计要点：
/// - 只解析、不重造 XML；未知节点（Times/AutoType/History/扩展）原样保留。
/// - 受保护字段在解析时按 inner stream 顺序解密、写回时按同一文档顺序重新加密。
/// - 保存时重新生成 master seed / IV / inner stream key，KDF 参数与算法保持原值。
/// - `close()` 丢弃全部明文字段引用（Swift String 无法保证内存清零，但引用与缓存全部释放）。
public final class KeePassNativeDocument {
    public let container: KeePassNativeContainer
    public let sourceName: String?
    public let headerSummary: KeePassHeaderSummary
    public let credentials: KeePassUnlockCredentials
    public let cipher: KeePassKdbxCipherAlgorithm
    public let compression: KeePassKdbxCompressionAlgorithm
    public let kdfParameters: KeePassKdbxKdfParameters
    public let innerRandomStreamID: UInt32?
    public let hasProtectedValues: Bool

    private var xmlRoot: KeePassXMLNode
    private var binaries: [Data]
    private let unknownInnerHeaderFields: [KeePassNativeKdbxWriter.InnerHeaderField]
    private var baselineSignature: String
    public private(set) var isClosed = false

    private init(
        container: KeePassNativeContainer,
        sourceName: String?,
        headerSummary: KeePassHeaderSummary,
        credentials: KeePassUnlockCredentials,
        cipher: KeePassKdbxCipherAlgorithm,
        compression: KeePassKdbxCompressionAlgorithm,
        kdfParameters: KeePassKdbxKdfParameters,
        innerRandomStreamID: UInt32?,
        xmlRoot: KeePassXMLNode,
        binaries: [Data],
        unknownInnerHeaderFields: [KeePassNativeKdbxWriter.InnerHeaderField]
    ) {
        self.container = container
        self.sourceName = sourceName
        self.headerSummary = headerSummary
        self.credentials = credentials
        self.cipher = cipher
        self.compression = compression
        self.kdfParameters = kdfParameters
        self.innerRandomStreamID = innerRandomStreamID
        self.xmlRoot = xmlRoot
        self.binaries = binaries
        self.unknownInnerHeaderFields = unknownInnerHeaderFields
        self.hasProtectedValues = xmlRoot.containsProtectedValue
        self.baselineSignature = Self.signature(of: xmlRoot)
    }

    public static func load(
        data: Data,
        sourceName: String? = nil,
        credentials: KeePassUnlockCredentials
    ) throws -> KeePassNativeDocument {
        guard KeePassFormatInspector.detect(data, sourceName: sourceName) == .kdbx else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "仅支持 KDBX 数据库；该文件不是有效的 KDBX 或已损坏。"
            )
        }

        let candidates = credentials.credentialCandidates
        guard !candidates.isEmpty else {
            throw KeePassOperationError(
                code: .invalidCredential,
                message: "请输入数据库密码或选择密钥文件。"
            )
        }

        var lastError: Error?
        for candidate in candidates {
            do {
                return try loadDatabase(
                    data,
                    sourceName: sourceName,
                    credentials: credentials,
                    candidate: candidate
                )
            } catch let error as KeePassOperationError where error.code == .invalidCredential {
                lastError = error
                continue
            } catch {
                throw error
            }
        }
        throw lastError ?? KeePassOperationError(
            code: .invalidCredential,
            message: "数据库密码或密钥文件不正确。"
        )
    }

    private static func loadDatabase(
        _ data: Data,
        sourceName: String?,
        credentials: KeePassUnlockCredentials,
        candidate: KeePassCredentialCandidate
    ) throws -> KeePassNativeDocument {
        let context = try KeePassKdbxDecryptInputContext.build(
            database: data,
            sourceName: sourceName,
            credentialCandidate: candidate
        )
        let headerSummary = context.envelope.headerSummary

        let container: KeePassNativeContainer
        switch headerSummary.formatVersion {
        case .kdbx3:
            container = .kdbx3
        case .kdbx4:
            container = .kdbx4
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "无法打开未知版本的 KDBX 文件。"
            )
        }

        guard let kdfParameters = context.kdfParameters else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX KDF 参数缺失；请确认文件未损坏。"
            )
        }
        guard let cipher = headerSummary.cryptoSummary?.cipher else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX cipher 参数缺失；请确认文件未损坏。"
            )
        }
        guard let compression = headerSummary.cryptoSummary?.compression else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX 压缩参数缺失；请确认文件未损坏。"
            )
        }

        let decryptedPayload = try DefaultKeePassKdbxPayloadDecryptor().decryptPayload(context)

        var payload = decryptedPayload
        var binaries: [Data] = []
        var unknownFields: [KeePassNativeKdbxWriter.InnerHeaderField] = []
        var innerRandomStreamID = context.cryptoInputs.innerRandomStreamID
        var innerRandomStreamKey = context.cryptoInputs.innerRandomStreamKey

        if container == .kdbx4 {
            let innerHeader = try KeePassNativeInnerHeader.parse(decryptedPayload)
            payload = innerHeader.payload
            binaries = innerHeader.binaries
            unknownFields = innerHeader.unknownFields
            innerRandomStreamID = innerHeader.innerRandomStreamID ?? innerRandomStreamID
            innerRandomStreamKey = innerHeader.innerRandomStreamKey ?? innerRandomStreamKey
        }

        if payload.starts(with: [0x1F, 0x8B]) {
            guard let inflated = KeePassGzipPayloadInflator.inflate(payload) else {
                throw KeePassOperationError(
                    code: .formatUnsupported,
                    message: "KDBX XML 解压失败；请确认文件未损坏。"
                )
            }
            payload = inflated
        }

        let cryptoInputs = KeePassKdbxPayloadCryptoInputs(
            masterSeed: context.cryptoInputs.masterSeed,
            encryptionIV: context.cryptoInputs.encryptionIV,
            innerRandomStreamKey: innerRandomStreamKey,
            streamStartBytes: context.cryptoInputs.streamStartBytes,
            innerRandomStreamID: innerRandomStreamID
        )
        let builder = KeePassNativeXMLTreeBuilder {
            try KeePassProtectedValueStreamDecoder.make(from: cryptoInputs)
        }
        let parser = XMLParser(data: payload)
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        guard parser.parse() else {
            throw builder.parseError ?? KeePassOperationError(
                code: .formatUnsupported,
                message: "KeePass XML 解析失败；请确认文件未损坏。"
            )
        }
        guard let root = builder.rootNode, root.name == "KeePassFile" else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KeePass XML 根节点无效；请确认文件未损坏。"
            )
        }

        return KeePassNativeDocument(
            container: container,
            sourceName: sourceName,
            headerSummary: headerSummary,
            credentials: credentials,
            cipher: cipher,
            compression: compression,
            kdfParameters: kdfParameters,
            innerRandomStreamID: innerRandomStreamID,
            xmlRoot: root,
            binaries: binaries,
            unknownInnerHeaderFields: unknownFields
        )
    }

    // MARK: 元信息

    public var displayName: String {
        headerSummary.displayName + "，\(kdfParameters.algorithm.displayName)，\(cipher.displayName)"
    }

    public var groupCount: Int {
        groups.count
    }

    public var entryCount: Int {
        allEntryDescriptors.count
    }

    public var binaryCount: Int {
        binaries.count
    }

    public var hasUnsavedChanges: Bool {
        guard !isClosed else { return false }
        return Self.signature(of: xmlRoot) != baselineSignature
    }

    public func containsElement(named name: String) -> Bool {
        xmlRoot.containsElement(named: name)
    }

    public func textValues(forElementNamed name: String) -> [String] {
        xmlRoot.textValues(forElementNamed: name)
    }

    /// 仅用于诊断与测试的短摘要（不含任何明文字段）。
    public var structureSummary: String {
        "\(container.displayName)，\(groupCount) 个分组，\(entryCount) 个条目，\(binaryCount) 个附件"
    }

    // MARK: 组树

    public var groups: [KeePassNativeGroup] {
        guard !isClosed, let rootGroup = rootGroupNode else { return [] }
        let recycleBinID = recycleBinUUID
        var result: [KeePassNativeGroup] = []
        var counters: [String: Int] = [:]

        func visit(
            _ node: KeePassXMLNode,
            parentID: String?,
            depth: Int,
            parentPath: String
        ) {
            let uuid = groupUUID(of: node)
            let title = node.firstChild(named: "Name")?.text ?? ""
            let path = parentPath.isEmpty ? title : parentPath + "/" + title
            let stableID: String
            if uuid.isEmpty {
                stableID = "missing-uuid:\(path)"
            } else {
                stableID = uuid
            }
            counters[stableID, default: 0] += 1
            if counters[stableID]! > 1 {
                // 理论上不会发生；出现重复 UUID 时用路径区分，避免 SwiftUI 列表崩溃。
                result.append(
                    KeePassNativeGroup(
                        id: "\(stableID)#\(counters[stableID]!)",
                        title: title,
                        parentID: parentID,
                        depth: depth,
                        path: path,
                        entryCount: node.children(named: "Entry").count,
                        childGroupCount: node.children(named: "Group").count,
                        isRecycleBin: !uuid.isEmpty && uuid == recycleBinID,
                        isRoot: parentID == nil
                    )
                )
            } else {
                result.append(
                    KeePassNativeGroup(
                        id: stableID,
                        title: title,
                        parentID: parentID,
                        depth: depth,
                        path: path,
                        entryCount: node.children(named: "Entry").count,
                        childGroupCount: node.children(named: "Group").count,
                        isRecycleBin: !uuid.isEmpty && uuid == recycleBinID,
                        isRoot: parentID == nil
                    )
                )
            }

            for child in node.children(named: "Group") {
                visit(child, parentID: stableID, depth: depth + 1, parentPath: path)
            }
        }

        visit(rootGroup, parentID: nil, depth: 0, parentPath: "")
        return result
    }

    public func group(id: String) -> KeePassNativeGroup? {
        groups.first { $0.id == id }
    }

    public var rootGroupID: String? {
        guard let rootGroup = rootGroupNode else { return nil }
        return groups.first?.id ?? groupUUID(of: rootGroup)
    }

    // MARK: 条目

    public var allEntries: [KeePassNativeEntry] {
        allEntryDescriptors
    }

    public func entry(id: String) -> KeePassNativeEntry? {
        allEntryDescriptors.first { $0.id == id }
    }

    /// 直接子条目；`groupID == nil` 表示根组。
    public func entries(inGroup groupID: String?) -> [KeePassNativeEntry] {
        guard !isClosed else { return [] }
        if let groupID {
            guard let node = groupNode(id: groupID) else { return [] }
            let descriptor = groups.first { $0.id == groupID }
            return node.children(named: "Entry").compactMap {
                entryDescriptor(
                    for: $0,
                    groupID: groupID,
                    groupPath: descriptor?.path ?? "",
                    isInRecycleBin: descriptor?.isRecycleBin == true
                )
            }
        }
        guard let rootGroup = rootGroupNode else { return [] }
        let rootDescriptor = groups.first { $0.isRoot }
        let rootID = rootDescriptor?.id ?? groupUUID(of: rootGroup)
        return rootGroup.children(named: "Entry").compactMap {
            entryDescriptor(
                for: $0,
                groupID: rootID,
                groupPath: rootDescriptor?.path ?? "",
                isInRecycleBin: false
            )
        }
    }

    public func entries(matching query: String) -> [KeePassNativeEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return allEntryDescriptors.filter { entry in
            entry.title.localizedCaseInsensitiveContains(trimmed)
                || entry.username.localizedCaseInsensitiveContains(trimmed)
                || entry.url.localizedCaseInsensitiveContains(trimmed)
                || entry.notes.localizedCaseInsensitiveContains(trimmed)
                || entry.groupPath.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var allEntryDescriptors: [KeePassNativeEntry] {
        guard !isClosed, let rootGroup = rootGroupNode else { return [] }
        var result: [KeePassNativeEntry] = []
        let recycleBinID = recycleBinUUID
        let rootDescriptor = groups.first { $0.isRoot }
        let rootID = rootDescriptor?.id ?? groupUUID(of: rootGroup)
        let rootPath = rootDescriptor?.path ?? ""

        func visit(_ node: KeePassXMLNode, groupID: String, groupPath: String, inRecycleBin: Bool) {
            for entry in node.children(named: "Entry") {
                if let descriptor = entryDescriptor(
                    for: entry,
                    groupID: groupID,
                    groupPath: groupPath,
                    isInRecycleBin: inRecycleBin
                ) {
                    result.append(descriptor)
                }
            }
            for child in node.children(named: "Group") {
                let uuid = groupUUID(of: child)
                let title = child.firstChild(named: "Name")?.text ?? ""
                let childPath = groupPath.isEmpty ? title : groupPath + "/" + title
                visit(
                    child,
                    groupID: uuid,
                    groupPath: childPath,
                    inRecycleBin: inRecycleBin || (!uuid.isEmpty && uuid == recycleBinID)
                )
            }
        }

        visit(rootGroup, groupID: rootID, groupPath: rootPath, inRecycleBin: !rootID.isEmpty && rootID == recycleBinID)
        return result
    }

    private func entryDescriptor(
        for node: KeePassXMLNode,
        groupID: String,
        groupPath: String,
        isInRecycleBin: Bool
    ) -> KeePassNativeEntry? {
        let uuid = node.firstChild(named: "UUID")?.trimmedText ?? ""
        guard !uuid.isEmpty else { return nil }

        var fields: [String: String] = [:]
        var protectedKeys: [String] = []
        for stringNode in node.children(named: "String") {
            guard let key = stringNode.firstChild(named: "Key")?.trimmedText else { continue }
            let valueNode = stringNode.firstChild(named: "Value")
            fields[key] = valueNode?.text ?? ""
            if valueNode?.isProtectedValue == true {
                protectedKeys.append(key)
            }
        }

        return KeePassNativeEntry(
            id: uuid,
            groupID: groupID,
            groupPath: groupPath,
            title: fields["Title"] ?? "",
            username: fields["UserName"] ?? "",
            password: fields["Password"] ?? "",
            url: fields["URL"] ?? "",
            notes: fields["Notes"] ?? "",
            hasPasswordField: fields["Password"] != nil,
            isInRecycleBin: isInRecycleBin,
            protectedFieldKeys: protectedKeys.sorted()
        )
    }

    // MARK: 组编辑

    @discardableResult
    public func createGroup(parentID: String?, title: String) throws -> KeePassNativeGroup {
        try ensureEditable()
        guard let sanitizedTitle = Self.sanitizedTitle(title) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "分组名称不能为空。"
            )
        }
        let parentPath = try groupPath(for: parentID)
        let uuid = Self.makeUUID()
        let now = KeePassNativeTimestamp.now()
        let group = KeePassXMLNode(
            name: "Group",
            children: [
                KeePassXMLNode(name: "UUID", text: uuid),
                KeePassXMLNode(name: "Name", text: sanitizedTitle),
                KeePassXMLNode(name: "Notes"),
                KeePassXMLNode(name: "IconID", text: "48"),
                KeePassXMLNode(
                    name: "Times",
                    children: [
                        KeePassXMLNode(name: "CreationTime", text: now),
                        KeePassXMLNode(name: "LastModificationTime", text: now),
                        KeePassXMLNode(name: "LastAccessTime", text: now),
                        KeePassXMLNode(name: "ExpiryTime", text: now),
                        KeePassXMLNode(name: "Expires", text: "False"),
                        KeePassXMLNode(name: "UsageCount", text: "0"),
                        KeePassXMLNode(name: "LocationChanged", text: now)
                    ]
                ),
                KeePassXMLNode(name: "IsExpanded", text: "True")
            ]
        )
        Self.appendChild(in: &xmlRoot.children, at: parentPath[...], child: group)
        guard let created = groups.first(where: { $0.id == uuid }) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "新建分组失败；请重试。"
            )
        }
        return created
    }

    public func renameGroup(id: String, title: String) throws {
        try ensureEditable()
        guard let sanitizedTitle = Self.sanitizedTitle(title) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "分组名称不能为空。"
            )
        }
        let path = try requiredGroupPath(id: id)
        Self.mutate(&xmlRoot.children, at: path[...]) { node in
            node.setChildText("Name", sanitizedTitle)
        }
    }

    public func moveGroup(id: String, toParentID: String?) throws {
        try ensureEditable()
        let sourcePath = try requiredGroupPath(id: id)
        let rootID = try rootGroupIdentifierForMutation()
        let rootPath = try requiredGroupPath(id: rootID)
        guard sourcePath != rootPath else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "根分组不能移动。"
            )
        }
        if let toParentID, toParentID == id {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "分组不能移动到自身。"
            )
        }
        if let toParentID, groupNode(id: id)?.containsGroup(uuid: toParentID) == true {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "分组不能移动到自己的子分组。"
            )
        }

        guard var sourceNode = Self.node(in: xmlRoot.children, at: sourcePath[...]) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "目标分组不存在。"
            )
        }
        // 先把源节点摘下来，再重新解析目标路径，避免下标漂移。
        Self.removeNode(in: &xmlRoot.children, at: sourcePath[...])
        let targetPath: [Int]
        do {
            targetPath = try groupPath(for: toParentID)
        } catch {
            // 回滚：按原路径尽量放回；失败则报告原始错误。
            Self.appendChild(in: &xmlRoot.children, at: sourcePath.dropLast()[...], child: sourceNode)
            throw error
        }
        // 移动会改变分组路径，更新 LocationChanged 时间戳；其余子节点（含未知节点）原样保留。
        if let timesIndex = sourceNode.children.firstIndex(where: { $0.name == "Times" }) {
            var times = sourceNode.children[timesIndex]
            let stamp = KeePassNativeTimestamp.now()
            if let index = times.children.firstIndex(where: { $0.name == "LocationChanged" }) {
                times.children[index].text = stamp
            } else {
                times.children.append(KeePassXMLNode(name: "LocationChanged", text: stamp))
            }
            sourceNode.children[timesIndex] = times
        }
        Self.appendChild(in: &xmlRoot.children, at: targetPath[...], child: sourceNode)
    }

    public func deleteGroup(id: String) throws {
        try ensureEditable()
        let path = try requiredGroupPath(id: id)
        let rootID = try rootGroupIdentifierForMutation()
        if id == rootID {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "根分组不能删除。"
            )
        }
        if let recycleBinID = recycleBinUUID, !recycleBinID.isEmpty, id == recycleBinID {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "回收站分组不能删除。"
            )
        }
        if let node = groupNode(id: id),
           let recycleBinID = recycleBinUUID,
           !recycleBinID.isEmpty,
           node.containsGroup(uuid: recycleBinID) {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "该分组包含回收站，不能删除。"
            )
        }
        Self.removeNode(in: &xmlRoot.children, at: path[...])
    }

    // MARK: 条目编辑

    public func updateEntry(
        id: String,
        title: String,
        username: String,
        password: String,
        url: String,
        notes: String
    ) throws {
        try ensureEditable()
        let path = try requiredEntryPath(id: id)
        let values: [(String, String)] = [
            ("Title", title),
            ("UserName", username),
            ("Password", password),
            ("URL", url),
            ("Notes", notes)
        ]
        Self.mutate(&xmlRoot.children, at: path[...]) { node in
            for (key, value) in values {
                Self.setEntryString(key: key, value: value, in: &node)
            }
            Self.touchLastModificationTime(in: &node)
        }
    }

    @discardableResult
    public func createEntry(
        groupID: String?,
        title: String,
        username: String = "",
        password: String = "",
        url: String = "",
        notes: String = ""
    ) throws -> KeePassNativeEntry {
        try ensureEditable()
        let path = try groupPath(for: groupID)
        let uuid = Self.makeUUID()
        let now = KeePassNativeTimestamp.now()
        let entry = KeePassXMLNode(
            name: "Entry",
            children: [
                KeePassXMLNode(name: "UUID", text: uuid),
                KeePassXMLNode(name: "IconID", text: "0"),
                KeePassXMLNode(
                    name: "Times",
                    children: [
                        KeePassXMLNode(name: "CreationTime", text: now),
                        KeePassXMLNode(name: "LastModificationTime", text: now),
                        KeePassXMLNode(name: "LastAccessTime", text: now),
                        KeePassXMLNode(name: "ExpiryTime", text: now),
                        KeePassXMLNode(name: "Expires", text: "False"),
                        KeePassXMLNode(name: "UsageCount", text: "0"),
                        KeePassXMLNode(name: "LocationChanged", text: now)
                    ]
                ),
                Self.stringNode(key: "Title", value: title),
                Self.stringNode(key: "UserName", value: username),
                Self.stringNode(key: "Password", value: password, isProtected: true),
                Self.stringNode(key: "URL", value: url),
                Self.stringNode(key: "Notes", value: notes)
            ]
        )
        Self.appendChild(in: &xmlRoot.children, at: path[...], child: entry)
        guard let created = allEntryDescriptors.first(where: { $0.id == uuid }) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "新建条目失败；请重试。"
            )
        }
        return created
    }

    private static func stringNode(
        key: String,
        value: String,
        isProtected: Bool = false
    ) -> KeePassXMLNode {
        KeePassXMLNode(
            name: "String",
            children: [
                KeePassXMLNode(name: "Key", text: key),
                KeePassXMLNode(
                    name: "Value",
                    attributes: isProtected ? [KeePassXMLAttribute(name: "Protected", value: "True")] : [],
                    text: value
                )
            ]
        )
    }

    // MARK: 写回

    public func makeDatabaseData() throws -> Data {
        let inputs = try KeePassNativeCryptoRandom.makeInputs(
            container: container,
            cipher: cipher,
            innerRandomStreamID: innerRandomStreamID
        )
        return try makeDatabaseData(cryptoInputs: inputs)
    }

    public func makeDatabaseData(cryptoInputs: KeePassKdbxPayloadCryptoInputs) throws -> Data {
        try ensureEditable()
        let encoder = try KeePassProtectedValueStreamEncoder.make(from: cryptoInputs)
        if hasProtectedValues, encoder == nil {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "当前 KDBX 缺少 inner stream key，无法安全写回受保护字段。"
            )
        }
        let xmlData = try KeePassNativeXMLRenderer.render(xmlRoot, protectedEncoder: encoder)
        return try KeePassNativeKdbxWriter().writeDatabase(
            xmlData: xmlData,
            container: container,
            cipher: cipher,
            compression: compression,
            kdfParameters: kdfParameters,
            credentials: credentials,
            cryptoInputs: cryptoInputs,
            binaries: binaries,
            unknownInnerHeaderFields: unknownInnerHeaderFields
        )
    }

    public var contentSignature: String {
        Self.signature(of: xmlRoot)
    }

    /// 写回成功后调用：把当前内容记为新的基线，`hasUnsavedChanges` 回到 false。
    public func markSaved() {
        guard !isClosed else { return }
        baselineSignature = Self.signature(of: xmlRoot)
    }

    public func close() {
        guard !isClosed else { return }
        xmlRoot = KeePassXMLNode(name: "KeePassFile")
        binaries = []
        isClosed = true
    }

    // MARK: 内部帮助

    private func ensureEditable() throws {
        guard !isClosed else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KeePass 库已关闭，请重新打开。"
            )
        }
    }

    private var rootGroupNode: KeePassXMLNode? {
        xmlRoot.firstChild(named: "Root")?.firstChild(named: "Group")
    }

    private var recycleBinUUID: String? {
        guard let value = xmlRoot.firstChild(named: "Meta")?
            .firstChild(named: "RecycleBinUUID")?
            .trimmedText,
            !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func groupUUID(of node: KeePassXMLNode) -> String {
        node.firstChild(named: "UUID")?.trimmedText ?? ""
    }

    private func rootGroupIdentifierForMutation() throws -> String {
        guard let rootGroup = rootGroupNode else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX 缺少根分组；请确认文件未损坏。"
            )
        }
        let uuid = groupUUID(of: rootGroup)
        guard !uuid.isEmpty else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "根分组缺少 UUID，无法编辑。"
            )
        }
        return uuid
    }

    private func groupNode(id: String) -> KeePassXMLNode? {
        guard !id.isEmpty, let rootGroup = rootGroupNode else { return nil }
        if groupUUID(of: rootGroup) == id {
            return rootGroup
        }
        return Self.findGroupNode(in: rootGroup.children(named: "Group"), id: id)
    }

    private static func findGroupNode(in nodes: [KeePassXMLNode], id: String) -> KeePassXMLNode? {
        for node in nodes where node.name == "Group" {
            if node.firstChild(named: "UUID")?.trimmedText == id {
                return node
            }
            if let found = findGroupNode(in: node.children(named: "Group"), id: id) {
                return found
            }
        }
        return nil
    }

    /// 返回相对 `xmlRoot.children` 的下标路径。
    private func groupPath(for groupID: String?) throws -> [Int] {
        if let groupID {
            return try requiredGroupPath(id: groupID)
        }
        let rootID = try rootGroupIdentifierForMutation()
        return try requiredGroupPath(id: rootID)
    }

    private func requiredGroupPath(id: String) throws -> [Int] {
        guard let path = Self.findPath(in: xmlRoot.children, where: { node in
            node.name == "Group" && node.firstChild(named: "UUID")?.trimmedText == id
        }) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "目标分组不存在，可能已被删除。"
            )
        }
        return path
    }

    private func requiredEntryPath(id: String) throws -> [Int] {
        guard let path = Self.findPath(in: xmlRoot.children, where: { node in
            node.name == "Entry" && node.firstChild(named: "UUID")?.trimmedText == id
        }) else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "目标条目不存在，可能已被删除。"
            )
        }
        return path
    }

    private static func setEntryString(key: String, value: String, in entry: inout KeePassXMLNode) {
        if let index = entry.children.firstIndex(where: { child in
            child.name == "String" && child.firstChild(named: "Key")?.trimmedText == key
        }) {
            var stringNode = entry.children[index]
            if let valueIndex = stringNode.children.firstIndex(where: { $0.name == "Value" }) {
                stringNode.children[valueIndex].text = value
            } else {
                stringNode.children.append(KeePassXMLNode(name: "Value", text: value))
            }
            // 保留原有的 Key 节点与保护标记（Protected / ProtectInMemory）。
            entry.children[index] = stringNode
            return
        }

        entry.children.append(
            KeePassXMLNode(
                name: "String",
                children: [
                    KeePassXMLNode(name: "Key", text: key),
                    KeePassXMLNode(name: "Value", text: value)
                ]
            )
        )
    }

    private static func touchLastModificationTime(in entry: inout KeePassXMLNode) {
        guard let timesIndex = entry.children.firstIndex(where: { $0.name == "Times" }) else {
            return
        }
        var times = entry.children[timesIndex]
        let stamp = KeePassNativeTimestamp.now()
        if let index = times.children.firstIndex(where: { $0.name == "LastModificationTime" }) {
            times.children[index].text = stamp
        } else {
            times.children.append(KeePassXMLNode(name: "LastModificationTime", text: stamp))
        }
        entry.children[timesIndex] = times
    }

    private static func sanitizedTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func makeUUID() -> String {
        KeePassNativeCryptoRandom.randomData(count: 16).base64EncodedString()
    }

    // 下标路径工具：所有路径都相对于 `xmlRoot.children`。

    private static func findPath(
        in nodes: [KeePassXMLNode],
        where predicate: (KeePassXMLNode) -> Bool
    ) -> [Int]? {
        for (index, node) in nodes.enumerated() {
            if predicate(node) {
                return [index]
            }
            if let subPath = findPath(in: node.children, where: predicate) {
                return [index] + subPath
            }
        }
        return nil
    }

    private static func node(in nodes: [KeePassXMLNode], at path: ArraySlice<Int>) -> KeePassXMLNode? {
        guard let first = path.first, nodes.indices.contains(first) else {
            return nil
        }
        if path.count == 1 {
            return nodes[first]
        }
        return node(in: nodes[first].children, at: path.dropFirst())
    }

    private static func mutate(
        _ nodes: inout [KeePassXMLNode],
        at path: ArraySlice<Int>,
        _ transform: (inout KeePassXMLNode) -> Void
    ) {
        guard let first = path.first, nodes.indices.contains(first) else {
            return
        }
        if path.count == 1 {
            transform(&nodes[first])
            return
        }
        var child = nodes[first]
        mutate(&child.children, at: path.dropFirst(), transform)
        nodes[first] = child
    }

    private static func appendChild(
        in nodes: inout [KeePassXMLNode],
        at path: ArraySlice<Int>,
        child: KeePassXMLNode
    ) {
        guard let first = path.first, nodes.indices.contains(first) else {
            return
        }
        if path.count == 1 {
            nodes[first].children.append(child)
            return
        }
        var node = nodes[first]
        appendChild(in: &node.children, at: path.dropFirst(), child: child)
        nodes[first] = node
    }

    private static func removeNode(in nodes: inout [KeePassXMLNode], at path: ArraySlice<Int>) {
        guard let first = path.first, nodes.indices.contains(first) else {
            return
        }
        if path.count == 1 {
            nodes.remove(at: first)
            return
        }
        var node = nodes[first]
        removeNode(in: &node.children, at: path.dropFirst())
        nodes[first] = node
    }

    private static func signature(of root: KeePassXMLNode) -> String {
        var hasher = SHA256()
        appendSignature(of: root, to: &hasher)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func appendSignature(of node: KeePassXMLNode, to hasher: inout SHA256) {
        hasher.update(data: Data(node.name.utf8))
        hasher.update(data: Data([0x00]))
        for attribute in node.attributes {
            hasher.update(data: Data(attribute.name.utf8))
            hasher.update(data: Data([0x3D]))
            hasher.update(data: Data(attribute.value.utf8))
            hasher.update(data: Data([0x00]))
        }
        hasher.update(data: Data([0x01]))
        if let text = node.text {
            hasher.update(data: Data(text.utf8))
        }
        hasher.update(data: Data([0x02]))
        for child in node.children {
            appendSignature(of: child, to: &hasher)
        }
        hasher.update(data: Data([0x03]))
    }
}

private extension KeePassXMLNode {
    var containsProtectedValue: Bool {
        if isProtectedValue {
            return true
        }
        return children.contains { $0.containsProtectedValue }
    }

    func containsGroup(uuid: String) -> Bool {
        if name == "Group", firstChild(named: "UUID")?.trimmedText == uuid {
            return true
        }
        return children.contains { $0.containsGroup(uuid: uuid) }
    }
}

// MARK: - 安全写回

/// 临时文件 + 重新打开校验 + 原子替换。
///
/// 校验失败（错误口令、未知格式、写回内容与编辑不一致）时源文件保持原样。
public struct KeePassNativeDocumentStore: Sendable {
    public init() {}

    public func save(
        document: KeePassNativeDocument,
        to url: URL
    ) throws -> KeePassNativeWriteBackOutcome {
        let database = try document.makeDatabaseData()
        return try replaceVerified(
            database: database,
            credentials: document.credentials,
            expectedContentSignature: document.contentSignature,
            at: url
        )
    }

    /// 写临时文件 → 从磁盘重新读回 → 用真实解密路径重新打开 → 通过后才原子替换。
    @discardableResult
    public func replaceVerified(
        database: Data,
        credentials: KeePassUnlockCredentials,
        expectedContentSignature: String,
        at url: URL
    ) throws -> KeePassNativeWriteBackOutcome {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).keepass-verify-\(UUID().uuidString)"
        )
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        do {
            try database.write(to: temporaryURL, options: [.atomic])
            let writtenData = try Data(contentsOf: temporaryURL)
            let reopened = try KeePassNativeDocument.load(
                data: writtenData,
                sourceName: url.lastPathComponent,
                credentials: credentials
            )
            guard reopened.contentSignature == expectedContentSignature else {
                throw KeePassOperationError(
                    code: .formatUnsupported,
                    message: "KeePass 写回校验失败：重新打开后的内容与当前编辑不一致，源文件未修改。"
                )
            }

            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(
                    url,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }

            return KeePassNativeWriteBackOutcome(
                databaseByteCount: writtenData.count,
                groupCount: reopened.groupCount,
                entryCount: reopened.entryCount
            )
        } catch let error as KeePassOperationError {
            throw error
        } catch {
            throw KeePassOperationError(
                code: .ioReadWriteFailed,
                message: "KeePass 数据库写回失败，源文件未修改：\(error.localizedDescription)"
            )
        }
    }
}
