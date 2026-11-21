//
//  MonicaSendPackage.swift
//  MonicaStorage
//
//  Monica Send：本地端到端加密分享包（issue #36）。
//
//  设计目标（与 issue #36 对齐）：
//  - 分享内容（文本 / 文件）只在设备上加密，明文绝不落盘、绝不进入 UserDefaults；
//  - 分享包 `*.send` 自带解密所需的全部材料，因此不依赖任何服务器；
//  - 解密密钥（token）只出现在分享码 / 链接 fragment 里，不写入分享包本身；
//  - 头部元数据（标题、文件名、过期时间、查看次数）参与 AEAD 的 AAD，被篡改后解密必然失败；
//  - 查看次数与过期时间由接收方在打开时强制执行：达到上限或过期后不再解密。
//
//  文件格式（大端）：
//    [0..<4)                 魔数 "MNS1"
//    [4..<8)                 头部 JSON 长度（UInt32 大端）
//    [8..<40)                盐 salt（32 字节，HKDF 用）
//    [40..<52)               包装密钥用的 nonce（12 字节）
//    [52..<64)               内容加密用的 nonce（12 字节）
//    [64..<64+n)             头部 JSON（UTF-8，键排序）
//    [64+n..<64+n+60)        被包装的内容密钥（AES-GCM combined：12+32+16）
//    [剩余]                  正文密文（AES-GCM combined：12+密文+16）
//
//  AAD = 除「被包装密钥」与「正文密文」之外的全部前置字节，
//  即 magic + 长度 + salt + 两个 nonce + 头部 JSON。
//
//  内容密钥（CEK）是 32 字节随机数，用 KEK 包装后放进分享包；
//  KEK = HKDF-SHA256(token, salt, info: "monica-send-v1", 32 字节)。
//  token 是 32 字节随机数，以 base64url（无填充）呈现为「分享码」，
//  也作为 `monica://send/<id>#<分享码>` 的 fragment。
//

import CryptoKit
import Foundation

// MARK: - 错误

/// 分享包在封装、解析、解密、消耗过程中可能出现的错误。
public enum MonicaSendPackageError: Error, LocalizedError, Sendable, Equatable {
    /// 容器结构损坏：魔数不符、长度越界、JSON 无法解析等。
    case invalidContainer
    /// 分享包版本高于本实现。
    case unsupportedVersion(Int)
    /// 分享码格式无效（长度不对、base64url 无法解码等）。
    case invalidCode
    /// AEAD 认证失败：分享码不正确，或密文 / 头部被篡改。
    case authenticationFailed
    /// 保险库处于锁定态，拒绝解密。
    case vaultLocked
    /// 分享包已过期。
    case expired(expiresAt: Date)
    /// 已达到查看次数上限。
    case viewLimitReached(maxViews: Int)
    /// 分享内容超过大小上限。
    case payloadTooLarge(limit: Int)
    /// 封装参数不合法（标题为空、标识非法、过期时间早于创建时间等）。
    case invalidPolicy(String)
    /// 查看次数账本无法读写（宁可拒绝解密，也不放开次数限制）。
    case consumptionLedgerUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidContainer:
            return "分享包格式无效或已损坏。"
        case .unsupportedVersion:
            return "分享包版本不受支持，请升级 Monica 后再试。"
        case .invalidCode:
            return "分享码格式无效。"
        case .authenticationFailed:
            return "分享码不正确，或分享包已损坏。"
        case .vaultLocked:
            return "保险库已锁定，无法解密分享包。"
        case .expired:
            return "分享包已过期并被销毁。"
        case .viewLimitReached:
            return "分享包已达到查看次数上限。"
        case .payloadTooLarge:
            return "分享内容超出大小上限。"
        case .invalidPolicy(let message):
            return message
        case .consumptionLedgerUnavailable:
            return "无法记录查看次数，已拒绝打开分享包。"
        }
    }
}

// MARK: - 基础类型

/// 分享包内承载的内容类型。
public enum MonicaSendContentKind: String, Codable, Sendable, CaseIterable {
    case text
    case file

    public var localizedName: String {
        switch self {
        case .text:
            return "文本"
        case .file:
            return "文件"
        }
    }
}

/// 分享包的封装参数。这些字段会写进头部，并受 AEAD 完整性保护。
public struct MonicaSendPolicy: Sendable, Equatable {
    /// 分享包标识，与本地 `LocalSendEntry.id` 对应。
    public let id: String
    public let kind: MonicaSendContentKind
    public let title: String
    public let fileName: String
    public let mediaType: String
    public let createdAt: Date
    /// `nil` 表示不设置过期时间。
    public let expiresAt: Date?
    /// 「N 次查看后销毁」里的 N，范围 1...999。
    public let maxViews: Int

    public init(
        id: String,
        kind: MonicaSendContentKind,
        title: String,
        fileName: String = "",
        mediaType: String = "",
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        maxViews: Int = 1
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.fileName = fileName
        self.mediaType = mediaType
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.maxViews = maxViews
    }
}

// MARK: - 分享码

/// 分享码：32 字节解密令牌的 base64url（无填充）表示。
///
/// 调用方必须把它当作机密处理：不写日志、不落盘、不放进 UserDefaults。
public struct MonicaSendCode: Sendable, Hashable {
    /// 令牌字节数。
    public static let tokenByteCount = 32

    /// 展示 / 复制用的 base64url 字符串。
    public let encoded: String
    private let tokenBytes: Data

    /// 用已有令牌构造分享码。
    public init(token: Data) throws {
        guard token.count == Self.tokenByteCount else {
            throw MonicaSendPackageError.invalidCode
        }
        self.tokenBytes = token
        self.encoded = MonicaSendBase64URL.encode(token)
    }

    /// 生成新的随机分享码。
    public static func generate() -> MonicaSendCode {
        let token = MonicaSendPackage.makeRandomBytes(count: tokenByteCount)
        return MonicaSendCode(uncheckedToken: token)
    }

    private init(uncheckedToken token: Data) {
        self.tokenBytes = token
        self.encoded = MonicaSendBase64URL.encode(token)
    }

    /// 解密令牌原始字节。必须在内存中使用，不要落盘。
    public var token: Data {
        tokenBytes
    }

    /// 把用户输入（分享码、`monica://send/...` 链接、带空白的粘贴内容）解析成分享码。
    public static func parse(_ text: String) throws -> MonicaSendCode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MonicaSendPackageError.invalidCode
        }
        if let code = MonicaSendLink.parseCodeFragment(from: trimmed) {
            return code
        }
        // 允许用户粘贴带空格 / 换行的分享码。
        let compact = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = MonicaSendBase64URL.decode(compact),
              data.count == Self.tokenByteCount else {
            throw MonicaSendPackageError.invalidCode
        }
        return try MonicaSendCode(token: data)
    }

}

/// 一次性分享链接：`monica://send/<分享包标识>#<分享码>`。
///
/// 分享码放在 fragment 里：fragment 不会出现在 HTTP 请求行 / 日志中，
/// 也不会被服务端看到——即便将来接入中继，这一约定也不变。
public struct MonicaSendLink: Sendable, Equatable {
    public static let scheme = "monica"
    public static let host = "send"

    public let packageID: String
    public let code: MonicaSendCode

    public init(packageID: String, code: MonicaSendCode) throws {
        guard MonicaSendPackage.isValidIdentifier(packageID) else {
            throw MonicaSendPackageError.invalidPolicy("分享包标识无效。")
        }
        self.packageID = packageID
        self.code = code
    }

    /// 可直接分享 / 复制的链接字符串。
    public var absoluteString: String {
        "\(Self.scheme)://\(Self.host)/\(packageID)#\(code.encoded)"
    }

    public func makeURL() throws -> URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = "/" + packageID
        components.fragment = code.encoded
        guard let url = components.url else {
            throw MonicaSendPackageError.invalidCode
        }
        return url
    }

    public static func parse(_ url: URL) -> MonicaSendLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard url.host()?.lowercased() == host else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count == 1, let fragment = url.fragment, !fragment.isEmpty else { return nil }
        guard let code = try? MonicaSendCode.parse(fragment) else { return nil }
        return try? MonicaSendLink(packageID: path[0], code: code)
    }

    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let link = MonicaSendLink.parse(url) else {
            return nil
        }
        self = link
    }

    /// 从字符串里提取分享码：既接受纯分享码，也接受 `monica://send/...#code`。
    static func parseCodeFragment(from text: String) -> MonicaSendCode? {
        guard text.lowercased().hasPrefix("\(scheme)://") else { return nil }
        guard let url = URL(string: text),
              let fragment = url.fragment,
              !fragment.isEmpty,
              let code = try? MonicaSendCode.parse(fragment) else {
            return nil
        }
        return code
    }
}

// MARK: - 描述符

/// 分享包的公开元数据（在输入分享码之前即可读取，用于展示过期时间 / 剩余次数）。
///
/// 注意：这些字段本身不加密（只受 AEAD 完整性保护），因此调用方不应把机密写进标题 / 文件名。
public struct MonicaSendPackageDescriptor: Sendable, Equatable {
    public let policy: MonicaSendPolicy
    /// 密文长度（AES-GCM combined），用于界面展示体积。
    public let ciphertextByteCount: Int

    public init(policy: MonicaSendPolicy, ciphertextByteCount: Int) {
        self.policy = policy
        self.ciphertextByteCount = ciphertextByteCount
    }

    public var id: String {
        policy.id
    }

    /// 查看次数账本的主键：同一个 Send 重新生成分享包后各算各的次数。
    public var ledgerKey: String {
        "\(policy.id)@\(Int(policy.createdAt.timeIntervalSince1970))"
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt = policy.expiresAt else { return false }
        return expiresAt <= now
    }

    /// 在已知已打开次数的情况下，还能打开几次。
    public func remainingViews(consumed: Int) -> Int {
        max(0, policy.maxViews - max(0, consumed))
    }
}

/// 封装结果：分享包字节 + 只应留在内存里的分享码。
public struct MonicaSendSealedPackage: Sendable, Equatable {
    public let data: Data
    public let descriptor: MonicaSendPackageDescriptor
    public let code: MonicaSendCode

    public init(data: Data, descriptor: MonicaSendPackageDescriptor, code: MonicaSendCode) {
        self.data = data
        self.descriptor = descriptor
        self.code = code
    }

    public var fileName: String {
        "\(descriptor.policy.id).\(MonicaSendPackage.fileExtension)"
    }

    public func makeLink() throws -> MonicaSendLink {
        try MonicaSendLink(packageID: descriptor.policy.id, code: code)
    }
}

/// 解密结果。
public struct MonicaSendOpenedPackage: Sendable, Equatable {
    public let descriptor: MonicaSendPackageDescriptor
    public let content: Data
    public let openedAt: Date
    /// 本次打开之前已经打开过的次数。
    public let opensBeforeThisOpen: Int
    /// 本次打开之后还能打开几次（0 表示这是最后一次）。
    public let remainingViews: Int

    public init(
        descriptor: MonicaSendPackageDescriptor,
        content: Data,
        openedAt: Date,
        opensBeforeThisOpen: Int,
        remainingViews: Int
    ) {
        self.descriptor = descriptor
        self.content = content
        self.openedAt = openedAt
        self.opensBeforeThisOpen = opensBeforeThisOpen
        self.remainingViews = remainingViews
    }

    /// 文本分享包的明文；非文本或不是合法 UTF-8 时返回 nil。
    public var text: String? {
        guard descriptor.policy.kind == .text else { return nil }
        return String(data: content, encoding: .utf8)
    }
}

// MARK: - 查看次数账本

/// 单个分享包的消耗记录。
public struct MonicaSendConsumptionRecord: Codable, Sendable, Equatable {
    public var openCount: Int
    public var firstOpenedAt: Date?
    public var lastOpenedAt: Date?

    public init(openCount: Int = 0, firstOpenedAt: Date? = nil, lastOpenedAt: Date? = nil) {
        self.openCount = openCount
        self.firstOpenedAt = firstOpenedAt
        self.lastOpenedAt = lastOpenedAt
    }
}

/// 本地查看次数账本：JSON 文件，按 `ledgerKey` 记录打开次数。
///
/// 没有服务器，所以次数只能在「接收方这台设备」上强制；
/// 账本损坏时宁可拒绝解密，也不放开次数限制。
public struct MonicaSendConsumptionLedger: Sendable {
    public static let defaultFileName = "monica-send-consumption.json"

    public let fileURL: URL

    /// `FileManager.default` 文档保证线程安全；用计算属性避免把非 Sendable 实例存进结构体。
    private var fileManager: FileManager {
        .default
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(directoryURL: URL) {
        self.fileURL = directoryURL.appendingPathComponent(Self.defaultFileName, isDirectory: false)
    }

    public func record(for ledgerKey: String) throws -> MonicaSendConsumptionRecord? {
        try loadRecords()[ledgerKey]
    }

    public func allRecords() throws -> [String: MonicaSendConsumptionRecord] {
        try loadRecords()
    }

    /// 记录一次成功打开，返回更新后的记录。
    @discardableResult
    public func registerOpen(for ledgerKey: String, at date: Date = Date()) throws -> MonicaSendConsumptionRecord {
        guard !ledgerKey.isEmpty else {
            throw MonicaSendPackageError.invalidPolicy("分享包标识无效。")
        }
        var records = try loadRecords()
        var record = records[ledgerKey] ?? MonicaSendConsumptionRecord()
        record.openCount += 1
        record.firstOpenedAt = record.firstOpenedAt ?? date
        record.lastOpenedAt = date
        records[ledgerKey] = record
        try persist(records)
        return record
    }

    /// 撤销某个分享包：把已用次数写满，任何副本再尝试打开都会命中次数上限。
    ///
    /// 没有服务器，撤销只能作用在「这台设备」的账本上；撤销记录会保留在账本里，
    /// 所以发送方删除本机分享包之后，同一台设备重新导入副本也无法解密。
    @discardableResult
    public func registerRevocation(
        for ledgerKey: String,
        at date: Date = Date()
    ) throws -> MonicaSendConsumptionRecord {
        guard !ledgerKey.isEmpty else {
            throw MonicaSendPackageError.invalidPolicy("分享包标识无效。")
        }
        var records = try loadRecords()
        var record = records[ledgerKey] ?? MonicaSendConsumptionRecord()
        record.openCount = Int.max
        record.firstOpenedAt = record.firstOpenedAt ?? date
        record.lastOpenedAt = date
        records[ledgerKey] = record
        try persist(records)
        return record
    }

    /// 清除某个分享包的记录（例如发送方主动销毁后重新生成）。
    public func removeRecord(for ledgerKey: String) throws {
        var records = try loadRecords()
        guard records.removeValue(forKey: ledgerKey) != nil else { return }
        try persist(records)
    }

    /// 清空全部记录。
    public func removeAllRecords() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            throw MonicaSendPackageError.consumptionLedgerUnavailable
        }
    }

    private func loadRecords() throws -> [String: MonicaSendConsumptionRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { return [:] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([String: MonicaSendConsumptionRecord].self, from: data)
        } catch {
            // 账本损坏时不能假装「还没打开过」，否则次数限制会被绕过。
            throw MonicaSendPackageError.consumptionLedgerUnavailable
        }
    }

    private func persist(_ records: [String: MonicaSendConsumptionRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(records)
            try ensureDirectory()
            #if os(iOS)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: fileURL, options: [.atomic])
            #endif
        } catch let error as MonicaSendPackageError {
            throw error
        } catch {
            throw MonicaSendPackageError.consumptionLedgerUnavailable
        }
    }

    private func ensureDirectory() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw MonicaSendPackageError.consumptionLedgerUnavailable
            }
            return
        }
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = directoryURL
            try? mutableDirectory.setResourceValues(values)
        } catch {
            throw MonicaSendPackageError.consumptionLedgerUnavailable
        }
    }
}

// MARK: - 容器编解码

/// 分享包二进制容器。
enum MonicaSendContainer {
    static let magic = Data("MNS1".utf8)
    static let version = 1
    static let fixedHeaderByteCount = 64
    static let saltByteCount = 32
    static let nonceByteCount = 12
    /// 被包装的内容密钥：12 字节 nonce + 32 字节密钥 + 16 字节 tag。
    static let wrappedKeyByteCount = 60
    static let tagByteCount = 16
    static let maximumHeaderByteCount = 65_536

    struct Parsed {
        let header: MonicaSendHeader
        let headerJSON: Data
        let salt: Data
        let keyNonce: Data
        let contentNonce: Data
        let wrappedKey: Data
        let ciphertext: Data
        /// 参与 AEAD 的前置字节（magic + 长度 + salt + nonce + 头部 JSON）。
        let aad: Data
    }

    struct MonicaSendHeader: Codable, Equatable, Sendable {
        var v: Int
        var id: String
        var kind: String
        var title: String
        var fileName: String
        var mediaType: String
        var createdAt: Double
        var expiresAt: Double?
        var maxViews: Int
        var ciphertextByteCount: Int
    }

    static func parse(_ data: Data) throws -> Parsed {
        guard data.count >= fixedHeaderByteCount + wrappedKeyByteCount else {
            throw MonicaSendPackageError.invalidContainer
        }
        let base = data.startIndex
        guard data[base ..< base + magic.count] == magic else {
            throw MonicaSendPackageError.invalidContainer
        }
        guard let headerLength = readUInt32(data, at: 4, base: base) else {
            throw MonicaSendPackageError.invalidContainer
        }
        guard headerLength > 0, headerLength <= UInt32(maximumHeaderByteCount) else {
            throw MonicaSendPackageError.invalidContainer
        }
        let headerStart = fixedHeaderByteCount
        let headerEnd = headerStart + Int(headerLength)
        guard headerEnd + wrappedKeyByteCount <= data.count else {
            throw MonicaSendPackageError.invalidContainer
        }

        let salt = data[base + 8 ..< base + 40]
        let keyNonce = data[base + 40 ..< base + 52]
        let contentNonce = data[base + 52 ..< base + 64]
        let headerJSON = data[base + headerStart ..< base + headerEnd]
        let wrappedKey = data[base + headerEnd ..< base + headerEnd + wrappedKeyByteCount]
        let ciphertext = data[base + headerEnd + wrappedKeyByteCount ..< data.endIndex]
        let aad = data[base ..< base + headerEnd]

        let header: MonicaSendHeader
        do {
            header = try JSONDecoder().decode(MonicaSendHeader.self, from: Data(headerJSON))
        } catch {
            throw MonicaSendPackageError.invalidContainer
        }
        guard header.v == version else {
            throw MonicaSendPackageError.unsupportedVersion(header.v)
        }
        guard header.ciphertextByteCount == ciphertext.count,
              header.ciphertextByteCount >= nonceByteCount + tagByteCount else {
            throw MonicaSendPackageError.invalidContainer
        }
        guard MonicaSendPackage.isValidIdentifier(header.id),
              MonicaSendContentKind(rawValue: header.kind) != nil,
              (1 ... MonicaSendPackage.maximumViewCount).contains(header.maxViews),
              header.ciphertextByteCount <= MonicaSendPackage.maximumPayloadByteCount + nonceByteCount + tagByteCount,
              header.title.count <= MonicaSendPackage.maximumTitleLength,
              header.fileName.count <= MonicaSendPackage.maximumFileNameLength,
              header.mediaType.count <= MonicaSendPackage.maximumMediaTypeLength else {
            throw MonicaSendPackageError.invalidContainer
        }

        return Parsed(
            header: header,
            headerJSON: Data(headerJSON),
            salt: Data(salt),
            keyNonce: Data(keyNonce),
            contentNonce: Data(contentNonce),
            wrappedKey: Data(wrappedKey),
            ciphertext: Data(ciphertext),
            aad: Data(aad)
        )
    }

    static func assemble(
        headerJSON: Data,
        salt: Data,
        keyNonce: Data,
        contentNonce: Data,
        wrappedKey: Data,
        ciphertext: Data
    ) -> Data {
        var data = Data()
        data.reserveCapacity(fixedHeaderByteCount + headerJSON.count + wrappedKey.count + ciphertext.count)
        data.append(magic)
        data.append(uint32Bytes(UInt32(headerJSON.count)))
        data.append(salt)
        data.append(keyNonce)
        data.append(contentNonce)
        data.append(headerJSON)
        data.append(wrappedKey)
        data.append(ciphertext)
        return data
    }

    static func aad(magicWithLength: Data, salt: Data, keyNonce: Data, contentNonce: Data, headerJSON: Data) -> Data {
        var data = Data()
        data.append(magicWithLength)
        data.append(salt)
        data.append(keyNonce)
        data.append(contentNonce)
        data.append(headerJSON)
        return data
    }

    static func magicWithLength(headerJSONLength: Int) -> Data {
        var data = magic
        data.append(uint32Bytes(UInt32(headerJSONLength)))
        return data
    }

    private static func readUInt32(_ data: Data, at offset: Int, base: Data.Index) -> UInt32? {
        guard data.count >= offset + 4 else { return nil }
        var value: UInt32 = 0
        for index in 0 ..< 4 {
            value = (value << 8) | UInt32(data[base + offset + index])
        }
        return value
    }

    static func uint32Bytes(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }
}

// MARK: - 封装 / 打开

/// Monica Send 分享包的封装与打开入口。
public enum MonicaSendPackage {
    /// 分享包文件扩展名。
    public static let fileExtension = "send"
    /// 分享包 UTI（App 侧 Info.plist 需同步登记）。
    public static let contentTypeIdentifier = "com.monicapass.monica.send"
    /// 单次分享内容上限：64 MiB。超过后请在 App 层提示用户改用其他方式。
    public static let maximumPayloadByteCount = 64 * 1024 * 1024
    /// 「最多查看次数」上限。
    public static let maximumViewCount = 999
    public static let maximumTitleLength = 200
    public static let maximumFileNameLength = 200
    public static let maximumMediaTypeLength = 120
    /// HKDF 的 info，改动会导致旧分享包无法解密。
    static let keyDerivationInfo = Data("monica-send-v1".utf8)

    // MARK: 封装

    /// 把明文封装成分享包。返回的 `code` 必须由调用方自行展示 / 分享，且不要落盘。
    public static func seal(
        policy: MonicaSendPolicy,
        content: Data,
        now: Date = Date()
    ) throws -> MonicaSendSealedPackage {
        try validate(policy: policy, content: content, now: now)

        let code = MonicaSendCode.generate()
        let salt = makeRandomBytes(count: MonicaSendContainer.saltByteCount)
        let keyNonce = AES.GCM.Nonce()
        let contentNonce = AES.GCM.Nonce()
        let keyNonceData = keyNonce.withUnsafeBytes { Data($0) }
        let contentNonceData = contentNonce.withUnsafeBytes { Data($0) }

        let ciphertextByteCount = content.count + MonicaSendContainer.nonceByteCount + MonicaSendContainer.tagByteCount
        let header = MonicaSendContainer.MonicaSendHeader(
            v: MonicaSendContainer.version,
            id: policy.id,
            kind: policy.kind.rawValue,
            title: policy.title.trimmingCharacters(in: .whitespacesAndNewlines),
            fileName: policy.fileName,
            mediaType: policy.mediaType,
            createdAt: policy.createdAt.timeIntervalSince1970,
            expiresAt: policy.expiresAt?.timeIntervalSince1970,
            maxViews: policy.maxViews,
            ciphertextByteCount: ciphertextByteCount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let headerJSON = try encoder.encode(header)

        let aad = MonicaSendContainer.aad(
            magicWithLength: MonicaSendContainer.magicWithLength(headerJSONLength: headerJSON.count),
            salt: salt,
            keyNonce: keyNonceData,
            contentNonce: contentNonceData,
            headerJSON: headerJSON
        )

        let contentKey = SymmetricKey(size: .bits256)
        let keyEncryptionKey = deriveKeyEncryptionKey(token: code.token, salt: salt)
        let wrapped = try AES.GCM.seal(
            contentKey.withUnsafeBytes { Data($0) },
            using: keyEncryptionKey,
            nonce: keyNonce,
            authenticating: aad
        )
        guard let wrappedCombined = wrapped.combined,
              wrappedCombined.count == MonicaSendContainer.wrappedKeyByteCount else {
            throw MonicaSendPackageError.invalidContainer
        }
        let sealed = try AES.GCM.seal(content, using: contentKey, nonce: contentNonce, authenticating: aad)
        guard let ciphertext = sealed.combined,
              ciphertext.count == ciphertextByteCount else {
            throw MonicaSendPackageError.invalidContainer
        }

        let data = MonicaSendContainer.assemble(
            headerJSON: headerJSON,
            salt: salt,
            keyNonce: keyNonceData,
            contentNonce: contentNonceData,
            wrappedKey: wrappedCombined,
            ciphertext: ciphertext
        )
        let descriptor = MonicaSendPackageDescriptor(policy: policy, ciphertextByteCount: ciphertextByteCount)
        return MonicaSendSealedPackage(data: data, descriptor: descriptor, code: code)
    }

    // MARK: 侦察

    /// 只读取头部元数据，不解密。用于导入前展示过期时间 / 次数 / 文件名。
    public static func inspect(_ data: Data) throws -> MonicaSendPackageDescriptor {
        let parsed = try MonicaSendContainer.parse(data)
        return descriptor(from: parsed)
    }

    // MARK: 打开

    /// 解开分享包并记录一次查看。
    ///
    /// 执行顺序是刻意的：先拒绝锁定态，再校验过期 / 次数，最后才解密。
    /// 任何一步失败都不会写入账本；成功解密后才 `registerOpen`。
    public static func open(
        _ data: Data,
        code: MonicaSendCode,
        ledger: MonicaSendConsumptionLedger,
        now: Date = Date(),
        isVaultLocked: Bool
    ) throws -> MonicaSendOpenedPackage {
        guard !isVaultLocked else {
            throw MonicaSendPackageError.vaultLocked
        }
        let parsed = try MonicaSendContainer.parse(data)
        let descriptor = descriptor(from: parsed)
        if let expiresAt = descriptor.policy.expiresAt, expiresAt <= now {
            throw MonicaSendPackageError.expired(expiresAt: expiresAt)
        }
        let existing = try ledger.record(for: descriptor.ledgerKey) ?? MonicaSendConsumptionRecord()
        if existing.openCount >= descriptor.policy.maxViews {
            throw MonicaSendPackageError.viewLimitReached(maxViews: descriptor.policy.maxViews)
        }

        let contentKeyData: Data
        do {
            let keyEncryptionKey = deriveKeyEncryptionKey(token: code.token, salt: parsed.salt)
            let box = try AES.GCM.SealedBox(combined: parsed.wrappedKey)
            contentKeyData = try AES.GCM.open(box, using: keyEncryptionKey, authenticating: parsed.aad)
        } catch {
            throw MonicaSendPackageError.authenticationFailed
        }
        guard contentKeyData.count == 32 else {
            throw MonicaSendPackageError.authenticationFailed
        }
        let content: Data
        do {
            let box = try AES.GCM.SealedBox(combined: parsed.ciphertext)
            content = try AES.GCM.open(box, using: SymmetricKey(data: contentKeyData), authenticating: parsed.aad)
        } catch {
            throw MonicaSendPackageError.authenticationFailed
        }

        let record = try ledger.registerOpen(for: descriptor.ledgerKey, at: now)
        return MonicaSendOpenedPackage(
            descriptor: descriptor,
            content: content,
            openedAt: now,
            opensBeforeThisOpen: record.openCount - 1,
            remainingViews: descriptor.remainingViews(consumed: record.openCount)
        )
    }

    /// 剩余可查看次数（账本不可读时返回 nil，由界面提示）。
    public static func remainingViews(
        for descriptor: MonicaSendPackageDescriptor,
        ledger: MonicaSendConsumptionLedger
    ) -> Int? {
        let records: [String: MonicaSendConsumptionRecord]
        do {
            records = try ledger.allRecords()
        } catch {
            return nil
        }
        return descriptor.remainingViews(consumed: records[descriptor.ledgerKey]?.openCount ?? 0)
    }

    // MARK: 内部

    /// 分享包标识的合法字符集：字母、数字、`.`、`_`、`-`，长度 1...64。
    /// 应用层复用它来决定「直接用 Send 条目 id 还是退回随机 UUID」。
    public static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func deriveKeyEncryptionKey(token: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: token),
            salt: salt,
            info: keyDerivationInfo,
            outputByteCount: 32
        )
    }

    private static func descriptor(from parsed: MonicaSendContainer.Parsed) -> MonicaSendPackageDescriptor {
        let header = parsed.header
        let kind = MonicaSendContentKind(rawValue: header.kind) ?? .text
        let policy = MonicaSendPolicy(
            id: header.id,
            kind: kind,
            title: header.title,
            fileName: header.fileName,
            mediaType: header.mediaType,
            createdAt: Date(timeIntervalSince1970: header.createdAt),
            expiresAt: header.expiresAt.map { Date(timeIntervalSince1970: $0) },
            maxViews: header.maxViews
        )
        return MonicaSendPackageDescriptor(policy: policy, ciphertextByteCount: header.ciphertextByteCount)
    }

    private static func validate(policy: MonicaSendPolicy, content: Data, now: Date) throws {
        guard isValidIdentifier(policy.id) else {
            throw MonicaSendPackageError.invalidPolicy("分享包标识无效。")
        }
        let title = policy.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw MonicaSendPackageError.invalidPolicy("分享标题不能为空。")
        }
        guard title.count <= maximumTitleLength else {
            throw MonicaSendPackageError.invalidPolicy("分享标题过长。")
        }
        guard policy.fileName.count <= maximumFileNameLength else {
            throw MonicaSendPackageError.invalidPolicy("文件名过长。")
        }
        guard policy.mediaType.count <= maximumMediaTypeLength else {
            throw MonicaSendPackageError.invalidPolicy("文件类型过长。")
        }
        guard (1 ... maximumViewCount).contains(policy.maxViews) else {
            throw MonicaSendPackageError.invalidPolicy("最多查看次数需要在 1 到 \(maximumViewCount) 之间。")
        }
        guard !content.isEmpty else {
            throw MonicaSendPackageError.invalidPolicy("没有可分享的内容。")
        }
        guard content.count <= maximumPayloadByteCount else {
            throw MonicaSendPackageError.payloadTooLarge(limit: maximumPayloadByteCount)
        }
        if let expiresAt = policy.expiresAt {
            guard expiresAt > now else {
                throw MonicaSendPackageError.invalidPolicy("过期时间必须晚于当前时间。")
            }
        }
    }

    static func makeRandomBytes(count: Int) -> Data {
        var bytes = Data()
        while bytes.count < count {
            bytes.append(contentsOf: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        }
        return bytes.prefix(count)
    }
}

// MARK: - base64url

enum MonicaSendBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }
}

// MARK: - 过期时间解析

/// 把 Send 记录里自由文本的「过期时间」解析成绝对时间。
///
/// 旧的 Send 记录只保存字符串（用户手填「2026-12-31」这类内容），
/// 分享包需要绝对时间才能执行「过期自动销毁」，所以这里集中做解析：
/// - 只有日期时按当天 23:59:59 处理，避免中午生成、下午就过期；
/// - 无法识别时返回 nil（界面需要明确提示「不会自动过期」）。
public enum MonicaSendExpiry {
    public static let supportedFormatHint = "2026-12-31 18:00"

    private static let dateTimeFormats = [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy/MM/dd HH:mm:ss",
        "yyyy/MM/dd HH:mm"
    ]
    private static let dateOnlyFormats = [
        "yyyy-MM-dd",
        "yyyy/MM/dd",
        "yyyy年MM月dd日"
    ]

    public static func date(
        from text: String,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = timeZone
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.isLenient = false

        for format in dateTimeFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        for format in dateOnlyFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                var workingCalendar = calendar
                workingCalendar.timeZone = timeZone
                let startOfDay = workingCalendar.startOfDay(for: date)
                return startOfDay.addingTimeInterval(24 * 60 * 60 - 1)
            }
        }
        return nil
    }
}
