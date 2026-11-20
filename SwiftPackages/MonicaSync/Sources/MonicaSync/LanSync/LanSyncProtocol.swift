import Foundation

/// Wire-level constants for the Monica LAN sync MVP (issue #53).
///
/// The transport is TCP (via Network.framework) discovered with Bonjour.
/// Every frame is length-prefixed JSON: `[4-byte big-endian length][JSON body]`.
/// Handshake frames travel in clear text (they contain only public keys and
/// key-confirmation MACs). After pairing is confirmed every application message
/// travels inside a `.sealed` frame (AES-GCM, see `LanSyncSecureChannel`).
public enum LanSyncProtocolSpec {
    public static let version: UInt16 = 1
    public static let magic = Data("MNSY".utf8)
    public static let frameLengthHeaderBytes = 4
    public static let maxFrameBytes = 24 * 1024 * 1024
    public static let bonjourServiceType = "_monica-sync._tcp"
    public static let bonjourDomain = "local."
    public static let defaultPairingPort: UInt16 = 49_803
    public static let shortCodeDigits = 6
    public static let pairingSessionLifetime: TimeInterval = 120
    public static let maxPairingFailureCount = 3
    public static let pairingFailureCooldown: TimeInterval = 30
    public static let syncStateFileName = "lan-sync-state-v1.json"
    public static let snapshotFormatVersion = 1
    public static let syncStateFormatVersion = 1
    public static let identityKeyChainService = "com.monicapass.monica.lansync"
    public static let identityKeyChainAccount = "device-identity-v1"
    public static let identityKeyChainLegacyAccount = "device-identity"
}

public enum LanSyncFrameKind: String, Codable, Sendable, Equatable, CaseIterable {
    case hello
    case helloReply
    case keyConfirmation
    case keyConfirmationReply
    case sessionConfirm
    case sealed
    case error

    public var isHandshakeFrame: Bool {
        switch self {
        case .hello, .helloReply, .keyConfirmation, .keyConfirmationReply, .sessionConfirm:
            true
        case .sealed, .error:
            false
        }
    }
}

/// A single wire frame. `sequence` is a per-direction counter used to reject
/// replayed frames; handshake and sealed channels keep separate sequence spaces.
public struct LanSyncFrame: Codable, Sendable, Equatable {
    public var version: UInt16
    public var kind: LanSyncFrameKind
    public var sequence: UInt64
    public var payload: Data

    public init(
        version: UInt16 = LanSyncProtocolSpec.version,
        kind: LanSyncFrameKind,
        sequence: UInt64,
        payload: Data
    ) {
        self.version = version
        self.kind = kind
        self.sequence = sequence
        self.payload = payload
    }
}

public enum LanSyncWireError: Error, Sendable, Equatable, LocalizedError {
    case frameTooLarge(Int)
    case malformedFrame(String)
    case unsupportedProtocolVersion(UInt16)
    case replayedSequence(expected: UInt64, received: UInt64)
    case unexpectedFrameKind(expected: String, received: LanSyncFrameKind)
    case decryptionFailed
    case authenticationFailed
    case pairingExpired
    case invalidPayload(String)

    public var errorDescription: String? {
        switch self {
        case .frameTooLarge(let bytes):
            "局域网同步数据帧过大（\(bytes) 字节），已中止本次传输。"
        case .malformedFrame(let detail):
            "局域网同步数据帧格式错误：\(detail)"
        case .unsupportedProtocolVersion(let version):
            "对端设备使用的同步协议版本（v\(version)）与本机不兼容。"
        case .replayedSequence:
            "检测到重复或乱序的同步数据帧，已中止连接。"
        case .unexpectedFrameKind:
            "对端发送了未预期的同步消息，已中止连接。"
        case .decryptionFailed, .authenticationFailed:
            "同步信道校验失败，数据可能被篡改，已中止本次同步。"
        case .pairingExpired:
            "配对码已过期，请重新发起配对。"
        case .invalidPayload(let detail):
            "同步消息内容无效：\(detail)"
        }
    }
}

public enum LanSyncFrameCodec {
    public static func encode(_ frame: LanSyncFrame) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(frame)
        guard body.count <= LanSyncProtocolSpec.maxFrameBytes else {
            throw LanSyncWireError.frameTooLarge(body.count)
        }
        var output = Data()
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        output.append(body)
        return output
    }

    public static func decode(_ body: Data) throws -> LanSyncFrame {
        guard body.count <= LanSyncProtocolSpec.maxFrameBytes else {
            throw LanSyncWireError.frameTooLarge(body.count)
        }
        let frame: LanSyncFrame
        do {
            frame = try JSONDecoder().decode(LanSyncFrame.self, from: body)
        } catch {
            throw LanSyncWireError.malformedFrame(String(describing: error))
        }
        guard frame.version == LanSyncProtocolSpec.version else {
            throw LanSyncWireError.unsupportedProtocolVersion(frame.version)
        }
        return frame
    }
}

/// Incremental decoder for the length-prefixed frame stream. A TCP receive may
/// deliver a partial frame or several frames at once; callers append chunks and
/// receive every complete frame.
public struct LanSyncFrameStreamDecoder: Sendable {
    private var buffer = Data()
    private let maxFrameBytes: Int

    public init(maxFrameBytes: Int = LanSyncProtocolSpec.maxFrameBytes) {
        self.maxFrameBytes = maxFrameBytes
    }

    public mutating func append(_ chunk: Data) throws -> [LanSyncFrame] {
        buffer.append(chunk)
        var frames: [LanSyncFrame] = []
        while buffer.count >= LanSyncProtocolSpec.frameLengthHeaderBytes {
            let length = try Self.readLength(buffer)
            guard length > 0 else {
                throw LanSyncWireError.malformedFrame("空数据帧")
            }
            guard length <= maxFrameBytes else {
                throw LanSyncWireError.frameTooLarge(length)
            }
            let total = LanSyncProtocolSpec.frameLengthHeaderBytes + length
            guard buffer.count >= total else {
                break
            }
            let start = buffer.startIndex + LanSyncProtocolSpec.frameLengthHeaderBytes
            let end = buffer.startIndex + total
            let body = Data(buffer[start..<end])
            frames.append(try LanSyncFrameCodec.decode(body))
            buffer.removeFirst(total)
        }
        return frames
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }

    public var hasBufferedBytes: Bool {
        !buffer.isEmpty
    }

    private static func readLength(_ buffer: Data) throws -> Int {
        guard buffer.count >= LanSyncProtocolSpec.frameLengthHeaderBytes else {
            throw LanSyncWireError.malformedFrame("帧长度头不完整")
        }
        var value: UInt32 = 0
        for index in 0..<LanSyncProtocolSpec.frameLengthHeaderBytes {
            value = (value << 8) | UInt32(buffer[buffer.startIndex + index])
        }
        return Int(value)
    }
}
