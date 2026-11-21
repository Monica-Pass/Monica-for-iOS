//
//  VaultSnapshot.swift
//  MonicaStorage
//
//  MDBX 保险库的一致性检查点快照（#30）。
//
//  设计要点：
//  1. 快照不是「在线复制正在写入的 .mdbx 文件」。上游 mdbx-ffi 目前没有暴露
//     checkpoint / snapshot 原语（见 issue #30 的跨仓依赖），因此本文件只接受
//     **已经静默（quiesced）** 的保险库文件：调用方必须先把 FFI 连接关掉。
//     判定方式不是靠调用方自觉，而是拒绝任何还带着非空 `-wal` / `-shm`
//     侧车文件的保险库 —— SQLite 在最后一个连接关闭时会清理侧车文件，
//     侧车非空就说明还有连接可能正在提交页。
//  2. 快照本体是「加密信封」：清单（标题/项目名等元数据）和保险库字节分别
//     用 AES-GCM 独立封装，密钥由 `VaultSnapshotKeyProviding` 提供（生产实现
//     把 32 字节随机密钥放进 Keychain）。清单单独封装是为了让列表页只解密
//     几 KB 的清单，而不是几 MB 的保险库。
//  3. 恢复是「先校验、再写临时文件、最后原子替换」：任何时候失败都不会让
//     目标保险库变成半写状态；恢复前一定会先给当前文件留一份
//     `.preRestoreSafety` 回滚点。
//  4. 保留策略：每个保险库最多保留 `retentionLimit` 份（默认 10，按创建时间
//     保留最新），超出后自动删除最旧的；`deleteAll` 提供显式清理入口。
//

import CryptoKit
import Foundation

// MARK: - 枚举编码

extension UnifiedVaultItemKind: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let kind = UnifiedVaultItemKind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "未知的条目类型：\(raw)"
            )
        }
        self = kind
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - 索引

/// 快照来自哪个动作：手动、锁库自动、还是恢复前的安全回滚点。
public enum VaultSnapshotReason: String, Codable, Sendable, CaseIterable {
    case manual
    case automaticLock
    case preRestoreSafety
}

/// 快照索引里的项目（文件夹）条目，只保留稳定主键与标题。
public struct VaultSnapshotProject: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// 快照索引里的一条条目指纹。
///
/// 只保存非敏感投影（标题、类型、所属项目、是否已删除）和内容摘要，
/// **不保存** 密码 / TOTP secret / 私钥 / 卡号 / Wi-Fi 密码等字段，
/// 因此即使索引被解密也只泄露「有哪些条目」。
public struct VaultSnapshotIndexItem: Codable, Sendable, Equatable, Identifiable {
    public let kind: UnifiedVaultItemKind
    public let entryID: String
    public let projectID: String
    public let title: String
    public let isDeleted: Bool
    public let digest: String

    public init(
        kind: UnifiedVaultItemKind,
        entryID: String,
        projectID: String,
        title: String,
        isDeleted: Bool,
        digest: String
    ) {
        self.kind = kind
        self.entryID = entryID
        self.projectID = projectID
        self.title = title
        self.isDeleted = isDeleted
        self.digest = digest
    }

    public var id: String { Self.identifier(kind: kind, entryID: entryID) }

    public static func identifier(kind: UnifiedVaultItemKind, entryID: String) -> String {
        "\(kind.rawValue):\(entryID)"
    }
}

/// 一份快照在创建时刻的条目/项目指纹总表。
public struct VaultSnapshotIndex: Codable, Sendable, Equatable {
    public let projects: [VaultSnapshotProject]
    public let items: [VaultSnapshotIndexItem]

    public init(projects: [VaultSnapshotProject] = [], items: [VaultSnapshotIndexItem] = []) {
        self.projects = projects
        self.items = items
    }

    public static let empty = VaultSnapshotIndex()

    public var isEmpty: Bool { projects.isEmpty && items.isEmpty }
    public var projectCount: Int { projects.count }
    public var itemCount: Int { items.count }
    public var deletedItemCount: Int { items.filter(\.isDeleted).count }
    public var liveItemCount: Int { itemCount - deletedItemCount }

    /// 按类型统计「未删除」条目数量，用于列表页展示。
    public func liveCountsByKind() -> [UnifiedVaultItemKind: Int] {
        var counts: [UnifiedVaultItemKind: Int] = [:]
        for item in items where !item.isDeleted {
            counts[item.kind, default: 0] += 1
        }
        return counts
    }

    public func item(kind: UnifiedVaultItemKind, entryID: String) -> VaultSnapshotIndexItem? {
        items.first { $0.kind == kind && $0.entryID == entryID }
    }
}

/// 从搜索投影构造快照索引。
///
/// 复用 `VaultSearchDocument`：它本身就是「全部条目的非敏感投影」，
/// 密码类字段在构造文档时已经被丢弃。摘要覆盖标题/账号/网址/备注/标签/
/// 收藏/删除/归档，不覆盖「最近查看」等使用统计，避免仅查看条目就产生差异。
public enum VaultSnapshotIndexBuilder {
    public static func index(
        projects: [VaultSnapshotProject],
        documents: [VaultSearchDocument]
    ) -> VaultSnapshotIndex {
        let items = documents.map { document in
            VaultSnapshotIndexItem(
                kind: document.kind,
                entryID: document.id,
                projectID: document.projectID,
                title: document.title,
                isDeleted: document.isDeleted,
                digest: digest(for: document)
            )
        }
        .sorted { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhs.entryID < rhs.entryID
        }
        return VaultSnapshotIndex(projects: projects, items: items)
    }

    /// 单条投影的内容摘要（长度前缀拼接，避免字段边界歧义）。
    public static func digest(for document: VaultSearchDocument) -> String {
        let fields: [String] = [
            document.kind.rawValue,
            document.id,
            document.projectID,
            document.title,
            document.username,
            document.url,
            document.details,
            document.notes,
            document.tags.joined(separator: "\u{1F}"),
            document.isFavorite ? "1" : "0",
            document.isDeleted ? "1" : "0",
            document.isArchived ? "1" : "0"
        ]
        let joined = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return VaultSnapshotCrypto.sha256Hex(of: Data(joined.utf8))
    }
}

// MARK: - 差异

public enum VaultSnapshotChange: String, Codable, Sendable, CaseIterable {
    /// 快照里有、当前没有：恢复会把这条加回来。
    case added
    /// 当前有、快照里没有：恢复会让这条消失（数据丢失风险）。
    case removed
    /// 两边都有但内容不同：恢复会覆盖当前内容。
    case modified
}

public struct VaultSnapshotDifference: Sendable, Equatable, Identifiable {
    public let change: VaultSnapshotChange
    public let kind: UnifiedVaultItemKind
    public let entryID: String
    public let snapshotTitle: String?
    public let currentTitle: String?
    public let snapshotDeleted: Bool
    public let currentDeleted: Bool

    public init(
        change: VaultSnapshotChange,
        kind: UnifiedVaultItemKind,
        entryID: String,
        snapshotTitle: String? = nil,
        currentTitle: String? = nil,
        snapshotDeleted: Bool = false,
        currentDeleted: Bool = false
    ) {
        self.change = change
        self.kind = kind
        self.entryID = entryID
        self.snapshotTitle = snapshotTitle
        self.currentTitle = currentTitle
        self.snapshotDeleted = snapshotDeleted
        self.currentDeleted = currentDeleted
    }

    public var id: String {
        "\(change.rawValue):\(kind.rawValue):\(entryID)"
    }

    public var displayTitle: String {
        snapshotTitle ?? currentTitle ?? entryID
    }
}

/// 「恢复这份快照会发生什么」：以快照为目标、当前库为基线。
public struct VaultSnapshotDiff: Sendable, Equatable {
    public let differences: [VaultSnapshotDifference]
    public let unchangedItemCount: Int
    public let snapshotItemCount: Int
    public let currentItemCount: Int

    public init(
        differences: [VaultSnapshotDifference] = [],
        unchangedItemCount: Int = 0,
        snapshotItemCount: Int = 0,
        currentItemCount: Int = 0
    ) {
        self.differences = differences
        self.unchangedItemCount = unchangedItemCount
        self.snapshotItemCount = snapshotItemCount
        self.currentItemCount = currentItemCount
    }

    public static let empty = VaultSnapshotDiff()

    public var isEmpty: Bool { differences.isEmpty }
    public var addedCount: Int { count(.added) }
    public var removedCount: Int { count(.removed) }
    public var modifiedCount: Int { count(.modified) }

    /// 恢复会造成当前条目消失，必须二次确认。
    public var isDestructive: Bool { removedCount > 0 }

    public func count(_ change: VaultSnapshotChange) -> Int {
        differences.filter { $0.change == change }.count
    }

    public func items(_ change: VaultSnapshotChange) -> [VaultSnapshotDifference] {
        differences.filter { $0.change == change }
    }

    /// 按类型 × 变更类型统计，UI 用来做分组摘要。
    public func countsByKind() -> [UnifiedVaultItemKind: [VaultSnapshotChange: Int]] {
        var result: [UnifiedVaultItemKind: [VaultSnapshotChange: Int]] = [:]
        for difference in differences {
            result[difference.kind, default: [:]][difference.change, default: 0] += 1
        }
        return result
    }
}

public enum VaultSnapshotDiffEngine {
    public static func diff(
        snapshot: VaultSnapshotIndex,
        current: VaultSnapshotIndex
    ) -> VaultSnapshotDiff {
        let currentByKey = Dictionary(
            current.items.map { (VaultSnapshotIndexItem.identifier(kind: $0.kind, entryID: $0.entryID), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let snapshotByKey = Dictionary(
            snapshot.items.map { (VaultSnapshotIndexItem.identifier(kind: $0.kind, entryID: $0.entryID), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var differences: [VaultSnapshotDifference] = []
        var unchanged = 0

        for item in snapshot.items {
            let key = item.id
            guard let currentItem = currentByKey[key] else {
                differences.append(
                    VaultSnapshotDifference(
                        change: .added,
                        kind: item.kind,
                        entryID: item.entryID,
                        snapshotTitle: item.title,
                        snapshotDeleted: item.isDeleted
                    )
                )
                continue
            }
            if currentItem.digest == item.digest {
                unchanged += 1
            } else {
                differences.append(
                    VaultSnapshotDifference(
                        change: .modified,
                        kind: item.kind,
                        entryID: item.entryID,
                        snapshotTitle: item.title,
                        currentTitle: currentItem.title,
                        snapshotDeleted: item.isDeleted,
                        currentDeleted: currentItem.isDeleted
                    )
                )
            }
        }

        for item in current.items where snapshotByKey[item.id] == nil {
            differences.append(
                VaultSnapshotDifference(
                    change: .removed,
                    kind: item.kind,
                    entryID: item.entryID,
                    currentTitle: item.title,
                    currentDeleted: item.isDeleted
                )
            )
        }

        differences.sort { lhs, rhs in
            if lhs.change.rawValue != rhs.change.rawValue {
                return lhs.change.rawValue < rhs.change.rawValue
            }
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhs.entryID < rhs.entryID
        }

        return VaultSnapshotDiff(
            differences: differences,
            unchangedItemCount: unchanged,
            snapshotItemCount: snapshot.itemCount,
            currentItemCount: current.itemCount
        )
    }
}

// MARK: - 清单 / 记录

public struct VaultSnapshotManifest: Codable, Sendable, Equatable, Identifiable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let id: String
    public let vaultID: String
    public let vaultDisplayName: String
    public let createdAt: Date
    public let reason: VaultSnapshotReason
    public let payloadByteCount: Int
    public let payloadSHA256: String
    public let index: VaultSnapshotIndex

    public init(
        formatVersion: Int = VaultSnapshotManifest.currentFormatVersion,
        id: String,
        vaultID: String,
        vaultDisplayName: String,
        createdAt: Date,
        reason: VaultSnapshotReason,
        payloadByteCount: Int,
        payloadSHA256: String,
        index: VaultSnapshotIndex
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.vaultID = vaultID
        self.vaultDisplayName = vaultDisplayName
        self.createdAt = createdAt
        self.reason = reason
        self.payloadByteCount = payloadByteCount
        self.payloadSHA256 = payloadSHA256
        self.index = index
    }

    public var itemCount: Int { index.itemCount }
    public var projectCount: Int { index.projectCount }
}

public struct VaultSnapshotRecord: Sendable, Equatable, Identifiable {
    public let manifest: VaultSnapshotManifest
    /// 信封文件自身的字节数（加密后），用于列表页展示磁盘占用。
    public let envelopeByteCount: Int
    public let fileURL: URL

    public init(manifest: VaultSnapshotManifest, envelopeByteCount: Int, fileURL: URL) {
        self.manifest = manifest
        self.envelopeByteCount = envelopeByteCount
        self.fileURL = fileURL
    }

    public var id: String { manifest.id }
}

public struct VaultSnapshotRestoreResult: Sendable, Equatable {
    public let manifest: VaultSnapshotManifest
    public let safetySnapshot: VaultSnapshotManifest?
    public let restoredPayloadSHA256: String
    public let replacedSidecars: [String]

    public init(
        manifest: VaultSnapshotManifest,
        safetySnapshot: VaultSnapshotManifest?,
        restoredPayloadSHA256: String,
        replacedSidecars: [String]
    ) {
        self.manifest = manifest
        self.safetySnapshot = safetySnapshot
        self.restoredPayloadSHA256 = restoredPayloadSHA256
        self.replacedSidecars = replacedSidecars
    }
}

// MARK: - 错误

public enum VaultSnapshotError: Error, Sendable, Equatable, LocalizedError {
    case emptyVaultIdentifier
    case vaultFileMissing(String)
    /// 侧车文件（`-wal` / `-shm`）非空：说明还有连接在进行事务，不能快照。
    case vaultNotQuiesced([String])
    case snapshotNotFound(String)
    case snapshotCorrupted
    case envelopeVersionUnsupported(Int)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case invalidSnapshotKey
    case snapshotKeyUnavailable(String)
    case restoreVerificationFailed(expected: String, actual: String)
    case vaultMismatch(expected: String, actual: String)
    case snapshotWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyVaultIdentifier:
            return "保险库标识为空，无法创建快照。"
        case .vaultFileMissing(let path):
            return "找不到保险库文件：\(path)"
        case .vaultNotQuiesced(let names):
            return "保险库仍有活动的写入连接（\(names.joined(separator: "、"))），拒绝在未静默状态下创建快照。"
        case .snapshotNotFound(let id):
            return "找不到快照：\(id)"
        case .snapshotCorrupted:
            return "快照内容已损坏或认证失败。"
        case .envelopeVersionUnsupported(let version):
            return "不支持的快照信封版本：\(version)"
        case .insufficientDiskSpace(let requiredBytes, let availableBytes):
            return "磁盘空间不足：恢复需要 \(requiredBytes) 字节，当前可用 \(availableBytes) 字节。"
        case .invalidSnapshotKey:
            return "快照密钥无效。"
        case .snapshotKeyUnavailable(let message):
            return "无法读取快照密钥：\(message)"
        case .restoreVerificationFailed(let expected, let actual):
            return "恢复校验失败：期望 \(expected)，实际 \(actual)。"
        case .vaultMismatch(let expected, let actual):
            return "快照不属于当前保险库：期望 \(expected)，实际 \(actual)。"
        case .snapshotWriteFailed(let message):
            return "写入快照失败：\(message)"
        }
    }
}

// MARK: - 加密

public enum VaultSnapshotCrypto {
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        sha256Hex(of: try Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    public static func randomKey() -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = Data(capacity: 32)
        for _ in 0..<32 {
            bytes.append(UInt8.random(in: 0...255, using: &generator))
        }
        return bytes
    }

    static func seal(_ plaintext: Data, key: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        do {
            let sealed = try AES.GCM.seal(plaintext, using: symmetricKey)
            guard let combined = sealed.combined else {
                throw VaultSnapshotError.invalidSnapshotKey
            }
            return combined
        } catch let error as VaultSnapshotError {
            throw error
        } catch {
            throw VaultSnapshotError.invalidSnapshotKey
        }
    }

    static func open(_ ciphertext: Data, key: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: symmetricKey)
        } catch {
            throw VaultSnapshotError.snapshotCorrupted
        }
    }
}

// MARK: - 密钥

/// 快照加密密钥来源。生产实现把 32 字节随机密钥存进 Keychain；
/// 测试可以用内存实现。密钥永远不会进入 UserDefaults / 日志 / 快照文件本身。
public protocol VaultSnapshotKeyProviding: Sendable {
    func snapshotKey(forVaultID vaultID: String) throws -> Data
}

// MARK: - 文件写入

public protocol VaultSnapshotFileWriting: Sendable {
    func write(_ data: Data, to url: URL) throws
}

public struct AtomicVaultSnapshotFileWriter: VaultSnapshotFileWriting {
    public init() {}

    public func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }
}

// MARK: - 存储

/// 加密快照仓库。
///
/// 目录布局：`<directoryURL>/<sanitized vaultID>/<snapshotID>.mvsnap`
/// 每个 `.mvsnap` 是一个信封：`magic(8) + manifestCipherLen(UInt32 BE) +
/// manifestCipher + payloadCipher`。
public struct VaultSnapshotStore: Sendable {
    public static let defaultRetentionLimit = 10
    public static let envelopeMagic = Data("MVSNAP02".utf8)
    public static let fileExtension = "mvsnap"

    public let directoryURL: URL
    public let retentionLimit: Int

    private let keyProvider: any VaultSnapshotKeyProviding
    private let fileWriter: any VaultSnapshotFileWriting
    private let capacityProvider: @Sendable (URL) -> Int64?

    public init(
        directoryURL: URL,
        keyProvider: any VaultSnapshotKeyProviding,
        retentionLimit: Int = VaultSnapshotStore.defaultRetentionLimit,
        fileWriter: any VaultSnapshotFileWriting = AtomicVaultSnapshotFileWriter(),
        capacityProvider: (@Sendable (URL) -> Int64?)? = nil
    ) {
        self.directoryURL = directoryURL
        self.keyProvider = keyProvider
        self.retentionLimit = max(1, retentionLimit)
        self.fileWriter = fileWriter
        self.capacityProvider = capacityProvider ?? VaultSnapshotStore.defaultAvailableCapacity
    }

    // MARK: 创建

    @discardableResult
    public func createSnapshot(
        vaultFileURL: URL,
        vaultID: String,
        vaultDisplayName: String,
        reason: VaultSnapshotReason,
        index: VaultSnapshotIndex,
        now: Date = Date()
    ) throws -> VaultSnapshotManifest {
        let vaultComponent = try sanitizedVaultComponent(vaultID)
        guard FileManager.default.fileExists(atPath: vaultFileURL.path) else {
            throw VaultSnapshotError.vaultFileMissing(vaultFileURL.path)
        }
        try ensureQuiesced(sidecarsOf: vaultFileURL)

        let payload = try Data(contentsOf: vaultFileURL, options: [.mappedIfSafe])
        let payloadDigest = VaultSnapshotCrypto.sha256Hex(of: payload)
        let manifest = VaultSnapshotManifest(
            id: UUID().uuidString,
            vaultID: vaultComponent,
            vaultDisplayName: vaultDisplayName,
            createdAt: now,
            reason: reason,
            payloadByteCount: payload.count,
            payloadSHA256: payloadDigest,
            index: index
        )

        let envelope = try envelopeData(manifest: manifest, payload: payload, vaultID: vaultID)
        let vaultDirectory = directoryURL.appendingPathComponent(vaultComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDirectory, withIntermediateDirectories: true)
        let fileURL = vaultDirectory.appendingPathComponent("\(manifest.id).\(Self.fileExtension)")
        do {
            try fileWriter.write(envelope, to: fileURL)
        } catch let error as VaultSnapshotError {
            throw error
        } catch {
            throw VaultSnapshotError.snapshotWriteFailed(error.localizedDescription)
        }

        pruneOrphans(in: vaultDirectory)
        try prune(vaultID: vaultComponent)
        return manifest
    }

    // MARK: 读取

    public func listSnapshots(vaultID: String) throws -> [VaultSnapshotRecord] {
        let vaultComponent = try sanitizedVaultComponent(vaultID)
        let directory = directoryURL.appendingPathComponent(vaultComponent, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        let key = try snapshotKey(forVaultID: vaultID)

        var records: [VaultSnapshotRecord] = []
        for fileURL in fileURLs where fileURL.pathExtension == Self.fileExtension {
            // 单个损坏的快照不应该让整个列表崩掉：跳过并继续。
            guard let manifest = try? readManifest(at: fileURL, key: key) else { continue }
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            records.append(
                VaultSnapshotRecord(
                    manifest: manifest,
                    envelopeByteCount: size,
                    fileURL: fileURL
                )
            )
        }
        return records.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    public func record(snapshotID: String, vaultID: String) throws -> VaultSnapshotRecord {
        let vaultComponent = try sanitizedVaultComponent(vaultID)
        let fileURL = fileURL(snapshotID: snapshotID, vaultComponent: vaultComponent)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw VaultSnapshotError.snapshotNotFound(snapshotID)
        }
        let key = try snapshotKey(forVaultID: vaultID)
        let manifest = try readManifest(at: fileURL, key: key)
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return VaultSnapshotRecord(manifest: manifest, envelopeByteCount: size, fileURL: fileURL)
    }

    /// 解密并校验一份快照：返回清单与「保险库字节的 SHA256 是否与清单一致」。
    public func verifySnapshot(
        snapshotID: String,
        vaultID: String
    ) throws -> (manifest: VaultSnapshotManifest, payloadSHA256: String) {
        let (manifest, payload) = try loadPayload(snapshotID: snapshotID, vaultID: vaultID)
        let digest = VaultSnapshotCrypto.sha256Hex(of: payload)
        guard digest == manifest.payloadSHA256 else {
            throw VaultSnapshotError.restoreVerificationFailed(
                expected: manifest.payloadSHA256,
                actual: digest
            )
        }
        return (manifest, digest)
    }

    // MARK: 恢复

    /// 恢复快照到保险库文件。
    ///
    /// - 前置条件：`vaultFileURL` 必须是静默状态（没有非空侧车文件），
    ///   调用方需要先关掉 FFI 连接并锁库。
    /// - 顺序：先给当前文件拍一份 `.preRestoreSafety` 回滚点 → 校验快照 →
    ///   检查磁盘余量 → 写同目录临时文件并回读校验 → 删除空侧车 →
    ///   原子替换。任何一步失败都不会触碰原文件。
    @discardableResult
    public func restoreSnapshot(
        snapshotID: String,
        vaultID: String,
        to vaultFileURL: URL,
        vaultDisplayName: String,
        currentIndex: VaultSnapshotIndex,
        createSafetySnapshot: Bool = true,
        now: Date = Date()
    ) throws -> VaultSnapshotRestoreResult {
        let vaultComponent = try sanitizedVaultComponent(vaultID)
        let (manifest, payload) = try loadPayload(snapshotID: snapshotID, vaultID: vaultID)
        guard manifest.vaultID == vaultComponent else {
            throw VaultSnapshotError.vaultMismatch(expected: vaultComponent, actual: manifest.vaultID)
        }
        guard manifest.payloadByteCount == payload.count else {
            throw VaultSnapshotError.restoreVerificationFailed(
                expected: "\(manifest.payloadByteCount) 字节",
                actual: "\(payload.count) 字节"
            )
        }
        let payloadDigest = VaultSnapshotCrypto.sha256Hex(of: payload)
        guard payloadDigest == manifest.payloadSHA256 else {
            throw VaultSnapshotError.restoreVerificationFailed(
                expected: manifest.payloadSHA256,
                actual: payloadDigest
            )
        }
        try ensureQuiesced(sidecarsOf: vaultFileURL)

        if let available = capacityProvider(vaultFileURL.deletingLastPathComponent()),
           available < Int64(payload.count) + 1_048_576 {
            throw VaultSnapshotError.insufficientDiskSpace(
                requiredBytes: Int64(payload.count) + 1_048_576,
                availableBytes: available
            )
        }

        var safetySnapshot: VaultSnapshotManifest?
        if createSafetySnapshot, FileManager.default.fileExists(atPath: vaultFileURL.path) {
            safetySnapshot = try createSnapshot(
                vaultFileURL: vaultFileURL,
                vaultID: vaultID,
                vaultDisplayName: vaultDisplayName,
                reason: .preRestoreSafety,
                index: currentIndex,
                now: now
            )
        }

        let directory = vaultFileURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".\(vaultFileURL.lastPathComponent).snapshot-restore-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try fileWriter.write(payload, to: temporaryURL)

            let written = try Data(contentsOf: temporaryURL)
            let writtenDigest = VaultSnapshotCrypto.sha256Hex(of: written)
            guard writtenDigest == manifest.payloadSHA256, written.count == payload.count else {
                throw VaultSnapshotError.restoreVerificationFailed(
                    expected: manifest.payloadSHA256,
                    actual: writtenDigest
                )
            }

            let sidecars = sidecarURLs(of: vaultFileURL).filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            for sidecar in sidecars {
                try FileManager.default.removeItem(at: sidecar)
            }

            if FileManager.default.fileExists(atPath: vaultFileURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    vaultFileURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: vaultFileURL)
            }

            return VaultSnapshotRestoreResult(
                manifest: manifest,
                safetySnapshot: safetySnapshot,
                restoredPayloadSHA256: payloadDigest,
                replacedSidecars: sidecars.map(\.lastPathComponent)
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    // MARK: 删除 / 保留策略

    public func deleteSnapshot(snapshotID: String, vaultID: String) throws {
        let vaultComponent = try sanitizedVaultComponent(vaultID)
        let fileURL = fileURL(snapshotID: snapshotID, vaultComponent: vaultComponent)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw VaultSnapshotError.snapshotNotFound(snapshotID)
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// 显式清理入口：删除该保险库的全部快照（不动保险库本体）。
    @discardableResult
    public func deleteAllSnapshots(vaultID: String) throws -> Int {
        let vaultComponent = try sanitizedVaultComponent(vaultID)
        let directory = directoryURL.appendingPathComponent(vaultComponent, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var removed = 0
        for fileURL in fileURLs where fileURL.pathExtension == Self.fileExtension {
            try FileManager.default.removeItem(at: fileURL)
            removed += 1
        }
        return removed
    }

    /// 按保留策略删除最旧的快照，返回被删除的 ID。
    @discardableResult
    public func prune(vaultID: String) throws -> [String] {
        let records = try listSnapshots(vaultID: vaultID)
        guard records.count > retentionLimit else { return [] }
        let doomed = records.suffix(records.count - retentionLimit)
        var removed: [String] = []
        for record in doomed {
            try? FileManager.default.removeItem(at: record.fileURL)
            removed.append(record.manifest.id)
        }
        return removed
    }

    // MARK: 内部

    private func sanitizedVaultComponent(_ vaultID: String) throws -> String {
        let trimmed = vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VaultSnapshotError.emptyVaultIdentifier }
        let allowed = trimmed.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "_"
        }
        let sanitized = String(allowed)
        guard !sanitized.isEmpty, sanitized != ".", sanitized != ".." else {
            throw VaultSnapshotError.emptyVaultIdentifier
        }
        return sanitized
    }

    private func fileURL(snapshotID: String, vaultComponent: String) -> URL {
        directoryURL
            .appendingPathComponent(vaultComponent, isDirectory: true)
            .appendingPathComponent("\(snapshotID).\(Self.fileExtension)")
    }

    private func snapshotKey(forVaultID vaultID: String) throws -> Data {
        let key: Data
        do {
            key = try keyProvider.snapshotKey(forVaultID: vaultID)
        } catch {
            throw VaultSnapshotError.snapshotKeyUnavailable(error.localizedDescription)
        }
        guard key.count == 32 else { throw VaultSnapshotError.invalidSnapshotKey }
        return key
    }

    private func envelopeData(
        manifest: VaultSnapshotManifest,
        payload: Data,
        vaultID: String
    ) throws -> Data {
        let key = try snapshotKey(forVaultID: vaultID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        let manifestCipher = try VaultSnapshotCrypto.seal(manifestData, key: key)
        let payloadCipher = try VaultSnapshotCrypto.seal(payload, key: key)

        var envelope = Data()
        envelope.append(Self.envelopeMagic)
        var length = UInt32(manifestCipher.count).bigEndian
        withUnsafeBytes(of: &length) { envelope.append(contentsOf: $0) }
        envelope.append(manifestCipher)
        envelope.append(payloadCipher)
        return envelope
    }

    private func readManifest(at fileURL: URL, key: Data) throws -> VaultSnapshotManifest {
        let data = try Data(contentsOf: fileURL)
        guard data.count > Self.envelopeMagic.count + 4 else {
            throw VaultSnapshotError.snapshotCorrupted
        }
        guard data.prefix(Self.envelopeMagic.count) == Self.envelopeMagic else {
            throw VaultSnapshotError.snapshotCorrupted
        }
        let lengthStart = data.index(data.startIndex, offsetBy: Self.envelopeMagic.count)
        let lengthEnd = data.index(lengthStart, offsetBy: 4)
        let manifestLength = Int(Self.readUInt32BigEndian(data[lengthStart..<lengthEnd]))
        guard manifestLength > 0, data.count >= lengthEnd + manifestLength else {
            throw VaultSnapshotError.snapshotCorrupted
        }
        let manifestEnd = data.index(lengthEnd, offsetBy: manifestLength)
        let plaintext = try VaultSnapshotCrypto.open(Data(data[lengthEnd..<manifestEnd]), key: key)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VaultSnapshotManifest.self, from: plaintext)
    }

    private func loadPayload(
        snapshotID: String,
        vaultID: String
    ) throws -> (manifest: VaultSnapshotManifest, payload: Data) {
        let vaultComponent = try sanitizedVaultComponent(vaultID)
        let fileURL = fileURL(snapshotID: snapshotID, vaultComponent: vaultComponent)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw VaultSnapshotError.snapshotNotFound(snapshotID)
        }
        let key = try snapshotKey(forVaultID: vaultID)
        let data = try Data(contentsOf: fileURL)
        guard data.count > Self.envelopeMagic.count + 4 else {
            throw VaultSnapshotError.snapshotCorrupted
        }
        guard data.prefix(Self.envelopeMagic.count) == Self.envelopeMagic else {
            throw VaultSnapshotError.snapshotCorrupted
        }
        let lengthStart = data.index(data.startIndex, offsetBy: Self.envelopeMagic.count)
        let lengthEnd = data.index(lengthStart, offsetBy: 4)
        let manifestLength = Int(Self.readUInt32BigEndian(data[lengthStart..<lengthEnd]))
        guard manifestLength > 0, data.count >= lengthEnd + manifestLength else {
            throw VaultSnapshotError.snapshotCorrupted
        }
        let manifestEnd = data.index(lengthEnd, offsetBy: manifestLength)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            VaultSnapshotManifest.self,
            from: try VaultSnapshotCrypto.open(Data(data[lengthEnd..<manifestEnd]), key: key)
        )
        guard manifest.formatVersion == VaultSnapshotManifest.currentFormatVersion else {
            throw VaultSnapshotError.envelopeVersionUnsupported(manifest.formatVersion)
        }
        let payload = try VaultSnapshotCrypto.open(Data(data[manifestEnd...]), key: key)
        return (manifest, payload)
    }

    private static func readUInt32BigEndian(_ bytes: Data.SubSequence) -> UInt32 {
        var value: UInt32 = 0
        for byte in bytes {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    private func sidecarURLs(of vaultFileURL: URL) -> [URL] {
        let path = vaultFileURL.path
        let base = path.hasSuffix(".mdbx") ? String(path.dropLast(".mdbx".count)) : path
        return [
            URL(fileURLWithPath: base + ".mdbx-wal"),
            URL(fileURLWithPath: base + ".mdbx-shm")
        ]
    }

    /// 静默判定：任何非空侧车文件都意味着可能还有连接在提交页。
    private func ensureQuiesced(sidecarsOf vaultFileURL: URL) throws {
        var busy: [String] = []
        for sidecar in sidecarsURLsCheckingExistence(vaultFileURL) {
            let size = (try? sidecar.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 0 {
                busy.append(sidecar.lastPathComponent)
            }
        }
        guard busy.isEmpty else {
            throw VaultSnapshotError.vaultNotQuiesced(busy)
        }
    }

    private func sidecarsURLsCheckingExistence(_ vaultFileURL: URL) -> [URL] {
        sidecarURLs(of: vaultFileURL).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func pruneOrphans(in directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for fileURL in contents where fileURL.lastPathComponent.hasPrefix(".") {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func defaultAvailableCapacity(for url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - 内存密钥（测试 / 预览）

/// 内存密钥提供者：只在测试与预览里使用，生产密钥必须进 Keychain。
public final class InMemoryVaultSnapshotKeyProvider: VaultSnapshotKeyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]

    public init(keys: [String: Data] = [:]) {
        self.keys = keys
    }

    public func snapshotKey(forVaultID vaultID: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let key = keys[vaultID] {
            return key
        }
        let key = VaultSnapshotCrypto.randomKey()
        keys[vaultID] = key
        return key
    }
}
