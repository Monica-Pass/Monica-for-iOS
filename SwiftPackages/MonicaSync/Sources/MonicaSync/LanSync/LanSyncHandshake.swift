import CryptoKit
import Foundation

// MARK: - Handshake payloads

public struct LanSyncHelloPayload: Codable, Sendable, Equatable {
    public var version: UInt16
    public var sessionID: String
    public var deviceID: String
    public var displayName: String
    public var signingPublicKey: Data
    public var ephemeralPublicKey: Data
    public var nonce: Data
    public var secretKind: LanSyncPairingSecretKind
}

public struct LanSyncHelloReplyPayload: Codable, Sendable, Equatable {
    public var version: UInt16
    public var sessionID: String
    public var deviceID: String
    public var displayName: String
    public var signingPublicKey: Data
    public var ephemeralPublicKey: Data
    public var nonce: Data
    public var signature: Data
}

public struct LanSyncKeyConfirmationPayload: Codable, Sendable, Equatable {
    public var sessionID: String
    public var signature: Data
    public var proof: Data
}

public struct LanSyncKeyConfirmationReplyPayload: Codable, Sendable, Equatable {
    public var sessionID: String
    public var signature: Data
    public var proof: Data
}

public struct LanSyncSessionConfirmPayload: Codable, Sendable, Equatable {
    public var sessionID: String
    public var proof: Data
}

public struct LanSyncErrorPayload: Codable, Sendable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - Expected peer (pinned identity)

public struct LanSyncExpectedPeer: Sendable, Equatable {
    public var deviceID: String
    public var signingPublicKey: Data
    public var displayName: String?

    public init(deviceID: String, signingPublicKey: Data, displayName: String? = nil) {
        self.deviceID = deviceID
        self.signingPublicKey = signingPublicKey
        self.displayName = displayName
    }
}

// MARK: - Handshake entropy

/// Injectable entropy so the handshake state machine can be tested
/// deterministically. Production callers use `.random()`.
public struct LanSyncHandshakeEntropy: Sendable, Equatable {
    public var sessionID: String
    public var nonce: Data
    public var ephemeralPrivateKeyMaterial: Data

    public init() {
        sessionID = Self.randomSessionID()
        nonce = LanSyncRandom.bytes(16)
        ephemeralPrivateKeyMaterial = LanSyncRandom.bytes(32)
    }

    public init(deterministicSeed: Data) {
        let material = LanSyncEncoding.hkdf(
            inputKeyMaterial: LanSyncEncoding.sha256(deterministicSeed),
            salt: Data("monica-lan-sync-entropy".utf8),
            info: Data("ephemeral-v1".utf8),
            outputByteCount: 64
        )
        let bytes = [UInt8](material)
        sessionID = LanSyncEncoding.hex(Data(bytes[0..<8]))
        nonce = Data(bytes[8..<24])
        ephemeralPrivateKeyMaterial = Data(bytes[24..<56])
    }

    static func randomSessionID() -> String {
        LanSyncEncoding.hex(LanSyncRandom.bytes(8))
    }

    func makeEphemeralKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        guard ephemeralPrivateKeyMaterial.count == 32 else {
            throw LanSyncHandshakeFailure.malformedPayload
        }
        do {
            return try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: ephemeralPrivateKeyMaterial
            )
        } catch {
            throw LanSyncHandshakeFailure.malformedPayload
        }
    }
}

// MARK: - State and outcome types

public enum LanSyncHandshakeState: Sendable, Equatable {
    case idle
    case awaitingHelloReply
    case awaitingKeyConfirmation
    case awaitingKeyConfirmationReply
    case awaitingUserVerification
    case awaitingPeerConfirmation
    case established
    case failed(LanSyncHandshakeFailure)
}

public struct LanSyncVerificationPrompt: Sendable, Equatable {
    public var codeDisplay: String
    public var peerDisplayName: String
    public var peerDeviceID: String
    public var peerFingerprint: String
}

public struct LanSyncHandshakeOutcome: Sendable {
    public var outgoingFrames: [LanSyncFrame]
    public var state: LanSyncHandshakeState
    public var verificationPrompt: LanSyncVerificationPrompt?
    public var session: LanSyncSessionKeys?
    public var failure: LanSyncHandshakeFailure?

    public var isEstablished: Bool {
        if case .established = state { return true }
        return false
    }
}

// MARK: - Failure type

public enum LanSyncHandshakeFailure: Error, Sendable, Equatable, LocalizedError {
    case malformedPayload
    case unexpectedFrame(kind: String, state: String)
    case invalidState(String)
    case unsupportedProtocolVersion(expected: UInt16, received: UInt16)
    case sessionMismatch
    case pairingSecretKindMismatch(expected: LanSyncPairingSecretKind, received: LanSyncPairingSecretKind)
    case invalidSignature(peer: String)
    case keyConfirmationFailed
    case identityMismatch
    case replayedSequence(expected: UInt64, received: UInt64)
    case userRejectedVerification
    case peerReportedError(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .malformedPayload:
            "配对数据格式无效，请重新发起配对。"
        case .unexpectedFrame:
            "配对过程中收到了意外数据，请重新发起配对。"
        case .invalidState:
            "配对状态异常，请返回并重新发起配对。"
        case .unsupportedProtocolVersion:
            "两台设备的局域网同步版本不兼容，请将 Monica 更新到最新版本。"
        case .sessionMismatch:
            "配对会话已失效，请重新发起配对。"
        case .pairingSecretKindMismatch:
            "配对方式不一致：请确认一端使用配对码、另一端输入同一配对码，或都使用二维码。"
        case .invalidSignature:
            "设备身份校验失败，可能有人正在尝试中间人攻击，已中止同步。"
        case .keyConfirmationFailed:
            "配对码不正确或连接被篡改，密钥确认失败，已中止同步。"
        case .identityMismatch:
            "对方设备身份与已配对记录不一致，为保护数据已中止同步。"
        case .replayedSequence:
            "配对消息重复或乱序，请重新发起配对。"
        case .userRejectedVerification:
            "两台设备显示的校验码不一致，已中止配对。请确认在同一 Wi-Fi 下并重新配对。"
        case .peerReportedError(_, let message):
            message
        }
    }
}

// MARK: - Handshake state machine

/// Transport-independent pairing handshake. The caller feeds it decoded frames
/// in arrival order and sends back the frames it returns; the network layer
/// only needs to move `LanSyncFrame` values.
public final class LanSyncHandshake: @unchecked Sendable {
    public let role: LanSyncRole
    public let localIdentity: LanSyncDeviceIdentity
    public let localDisplayName: String
    public let pairingSecret: LanSyncPairingSecret
    public let expectedPeer: LanSyncExpectedPeer?

    private let lock = NSLock()
    private var state: LanSyncHandshakeState = .idle
    private var entropy: LanSyncHandshakeEntropy?
    private var helloPayload: LanSyncHelloPayload?
    private var helloReplyPayload: LanSyncHelloReplyPayload?
    private var sessionKeys: LanSyncSessionKeys?
    private var transcriptHash: Data?
    private var sharedSecret: Data?
    private var outgoingSequence: UInt64 = 1
    private var lastIncomingSequence: UInt64 = 0
    private var peerConfirmed = false
    private var ownConfirmed = false
    private var peerVerificationPrompt: LanSyncVerificationPrompt?

    public init(
        role: LanSyncRole,
        identity: LanSyncDeviceIdentity,
        displayName: String,
        pairingSecret: LanSyncPairingSecret,
        expectedPeer: LanSyncExpectedPeer? = nil,
        entropy: LanSyncHandshakeEntropy? = nil
    ) {
        self.role = role
        localIdentity = identity
        localDisplayName = displayName
        self.pairingSecret = pairingSecret
        self.expectedPeer = expectedPeer
        self.entropy = entropy
    }

    public var currentState: LanSyncHandshakeState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public var verificationPrompt: LanSyncVerificationPrompt? {
        lock.lock()
        defer { lock.unlock() }
        return peerVerificationPrompt
    }

    /// Host: produces the initial `hello` frame. Guest: waits for `hello`, so
    /// this returns no frames.
    public func begin() throws -> LanSyncHandshakeOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard state == .idle else {
            throw LanSyncHandshakeFailure.invalidState("begin 只能调用一次")
        }
        guard role == .host else {
            return outcome(frames: [])
        }
        let entropy = entropy ?? LanSyncHandshakeEntropy()
        self.entropy = entropy
        let ephemeralKey = try entropy.makeEphemeralKey()
        let hello = LanSyncHelloPayload(
            version: LanSyncProtocolSpec.version,
            sessionID: entropy.sessionID,
            deviceID: localIdentity.deviceID,
            displayName: localDisplayName,
            signingPublicKey: localIdentity.signingPublicKey,
            ephemeralPublicKey: ephemeralKey.publicKey.rawRepresentation,
            nonce: entropy.nonce,
            secretKind: pairingSecret.kind
        )
        helloPayload = hello
        let frame = try makeFrame(kind: .hello, payloadValue: hello)
        state = .awaitingHelloReply
        return outcome(frames: [frame])
    }

    /// Feeds one decoded frame into the state machine.
    public func receive(_ frame: LanSyncFrame) throws -> LanSyncHandshakeOutcome {
        lock.lock()
        defer { lock.unlock() }
        do {
            return try receiveLocked(frame)
        } catch let failure as LanSyncHandshakeFailure {
            if case .failed = state {
                // Keep the original failure.
            } else {
                state = .failed(failure)
            }
            throw failure
        }
    }

    /// Called by the UI once the user has compared the short authentication code.
    /// Passing `false` aborts the session without ever announcing confirmation.
    public func confirmUserVerification(matches: Bool) -> LanSyncHandshakeOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard case .awaitingUserVerification = state else {
            let failure = LanSyncHandshakeFailure.invalidState("当前不在等待用户确认校验码")
            state = .failed(failure)
            return outcome(frames: [], failure: failure)
        }
        guard matches else {
            let failure = LanSyncHandshakeFailure.userRejectedVerification
            let errorFrame = try? makeFrame(
                kind: .error,
                payloadValue: LanSyncErrorPayload(
                    code: "user-rejected",
                    message: failure.errorDescription ?? "已取消配对"
                )
            )
            state = .failed(failure)
            return outcome(frames: errorFrame.map { [$0] } ?? [], failure: failure)
        }
        guard let keys = sessionKeys else {
            let failure = LanSyncHandshakeFailure.invalidState("缺少会话密钥")
            state = .failed(failure)
            return outcome(frames: [], failure: failure)
        }
        ownConfirmed = true
        let confirm = LanSyncSessionConfirmPayload(
            sessionID: keys.sessionID,
            proof: keys.sessionConfirmProof(for: role)
        )
        let frame = try? makeFrame(kind: .sessionConfirm, payloadValue: confirm)
        var frames: [LanSyncFrame] = []
        if let frame { frames.append(frame) }
        if peerConfirmed {
            state = .established
        } else {
            state = .awaitingPeerConfirmation
        }
        return outcome(frames: frames)
    }

    // MARK: - Receive paths

    private func receiveLocked(_ frame: LanSyncFrame) throws -> LanSyncHandshakeOutcome {
        guard frame.version == LanSyncProtocolSpec.version else {
            throw LanSyncHandshakeFailure.unsupportedProtocolVersion(
                expected: LanSyncProtocolSpec.version,
                received: frame.version
            )
        }
        guard frame.sequence > lastIncomingSequence else {
            throw LanSyncHandshakeFailure.replayedSequence(
                expected: lastIncomingSequence + 1,
                received: frame.sequence
            )
        }
        lastIncomingSequence = frame.sequence

        switch frame.kind {
        case .hello:
            return try guestHandleHello(frame)
        case .helloReply:
            return try hostHandleHelloReply(frame)
        case .keyConfirmation:
            return try guestHandleKeyConfirmation(frame)
        case .keyConfirmationReply:
            return try hostHandleKeyConfirmationReply(frame)
        case .sessionConfirm:
            return try handleSessionConfirm(frame)
        case .error:
            return try handlePeerError(frame)
        case .sealed:
            throw LanSyncHandshakeFailure.unexpectedFrame(kind: frame.kind.rawValue, state: stateName)
        }
    }

    private func guestHandleHello(_ frame: LanSyncFrame) throws -> LanSyncHandshakeOutcome {
        guard role == .guest, state == .idle else {
            throw LanSyncHandshakeFailure.unexpectedFrame(kind: "hello", state: stateName)
        }
        let hello: LanSyncHelloPayload = try decode(frame)
        guard hello.version == LanSyncProtocolSpec.version else {
            throw LanSyncHandshakeFailure.unsupportedProtocolVersion(
                expected: LanSyncProtocolSpec.version,
                received: hello.version
            )
        }
        guard hello.secretKind == pairingSecret.kind else {
            throw LanSyncHandshakeFailure.pairingSecretKindMismatch(
                expected: pairingSecret.kind,
                received: hello.secretKind
            )
        }
        try validatePublicMaterial(hello.signingPublicKey, hello.ephemeralPublicKey)
        if let expectedPeer, !matches(expectedPeer: expectedPeer, deviceID: hello.deviceID, publicKey: hello.signingPublicKey) {
            throw LanSyncHandshakeFailure.identityMismatch
        }

        let hostEphemeral = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: hello.ephemeralPublicKey
        )
        let entropy = self.entropy ?? LanSyncHandshakeEntropy()
        self.entropy = entropy
        let ephemeralKey = try entropy.makeEphemeralKey()
        let shared = try ephemeralKey.sharedSecretFromKeyAgreement(with: hostEphemeral)
        sharedSecret = shared.withUnsafeBytes { Data($0) }

        let unsignedReply = LanSyncHelloReplyPayload(
            version: LanSyncProtocolSpec.version,
            sessionID: hello.sessionID,
            deviceID: localIdentity.deviceID,
            displayName: localDisplayName,
            signingPublicKey: localIdentity.signingPublicKey,
            ephemeralPublicKey: ephemeralKey.publicKey.rawRepresentation,
            nonce: entropy.nonce,
            signature: Data()
        )
        let digest = try Self.transcriptDigest(hello: hello, reply: unsignedReply)
        var reply = unsignedReply
        reply.signature = try localIdentity.sign(digest)

        helloPayload = hello
        helloReplyPayload = reply
        transcriptHash = digest
        sessionKeys = LanSyncSessionKeys.derive(
            role: .guest,
            sessionID: hello.sessionID,
            sharedSecret: sharedSecret ?? Data(),
            pairingSecret: pairingSecret,
            transcriptHash: digest,
            peerDeviceID: hello.deviceID,
            peerDisplayName: hello.displayName,
            peerSigningPublicKey: hello.signingPublicKey
        )

        let outgoing = try makeFrame(kind: .helloReply, payloadValue: reply)
        state = .awaitingKeyConfirmation
        return outcome(frames: [outgoing])
    }

    private func hostHandleHelloReply(_ frame: LanSyncFrame) throws -> LanSyncHandshakeOutcome {
        guard role == .host, state == .awaitingHelloReply else {
            throw LanSyncHandshakeFailure.unexpectedFrame(kind: "helloReply", state: stateName)
        }
        guard let hello = helloPayload, let entropy else {
            throw LanSyncHandshakeFailure.invalidState("缺少主机握手状态")
        }
        let reply: LanSyncHelloReplyPayload = try decode(frame)
        guard reply.version == LanSyncProtocolSpec.version else {
            throw LanSyncHandshakeFailure.unsupportedProtocolVersion(
                expected: LanSyncProtocolSpec.version,
                received: reply.version
            )
        }
        guard reply.sessionID == hello.sessionID else {
            throw LanSyncHandshakeFailure.sessionMismatch
        }
        try validatePublicMaterial(reply.signingPublicKey, reply.ephemeralPublicKey)
        let unsignedReply = LanSyncHelloReplyPayload(
            version: reply.version,
            sessionID: reply.sessionID,
            deviceID: reply.deviceID,
            displayName: reply.displayName,
            signingPublicKey: reply.signingPublicKey,
            ephemeralPublicKey: reply.ephemeralPublicKey,
            nonce: reply.nonce,
            signature: Data()
        )
        let digest = try Self.transcriptDigest(hello: hello, reply: unsignedReply)
        guard LanSyncDeviceIdentity.verifySignature(
            reply.signature,
            data: digest,
            publicKey: reply.signingPublicKey
        ) else {
            throw LanSyncHandshakeFailure.invalidSignature(peer: reply.displayName)
        }
        if let expectedPeer,
           !matches(expectedPeer: expectedPeer, deviceID: reply.deviceID, publicKey: reply.signingPublicKey)
        {
            throw LanSyncHandshakeFailure.identityMismatch
        }

        let hostEphemeralKey = try entropy.makeEphemeralKey()
        let guestEphemeral = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: reply.ephemeralPublicKey
        )
        let shared = try hostEphemeralKey.sharedSecretFromKeyAgreement(with: guestEphemeral)
        sharedSecret = shared.withUnsafeBytes { Data($0) }
        transcriptHash = digest
        helloReplyPayload = reply

        guard let sharedSecret else {
            throw LanSyncHandshakeFailure.invalidState("缺少共享密钥")
        }
        let keys = LanSyncSessionKeys.derive(
            role: .host,
            sessionID: hello.sessionID,
            sharedSecret: sharedSecret,
            pairingSecret: pairingSecret,
            transcriptHash: digest,
            peerDeviceID: reply.deviceID,
            peerDisplayName: reply.displayName,
            peerSigningPublicKey: reply.signingPublicKey
        )
        sessionKeys = keys

        let confirmation = LanSyncKeyConfirmationPayload(
            sessionID: keys.sessionID,
            signature: try localIdentity.sign(digest),
            proof: keys.confirmationProof(for: .host)
        )
        let outgoing = try makeFrame(kind: .keyConfirmation, payloadValue: confirmation)
        state = .awaitingKeyConfirmationReply
        return outcome(frames: [outgoing])
    }

    private func guestHandleKeyConfirmation(_ frame: LanSyncFrame) throws -> LanSyncHandshakeOutcome {
        guard role == .guest, state == .awaitingKeyConfirmation else {
            throw LanSyncHandshakeFailure.unexpectedFrame(kind: "keyConfirmation", state: stateName)
        }
        guard let hello = helloPayload, let keys = sessionKeys, let digest = transcriptHash else {
            throw LanSyncHandshakeFailure.invalidState("缺少访客握手状态")
        }
        let confirmation: LanSyncKeyConfirmationPayload = try decode(frame)
        guard confirmation.sessionID == keys.sessionID else {
            throw LanSyncHandshakeFailure.sessionMismatch
        }
        guard LanSyncDeviceIdentity.verifySignature(
            confirmation.signature,
            data: digest,
            publicKey: hello.signingPublicKey
        ) else {
            throw LanSyncHandshakeFailure.invalidSignature(peer: hello.displayName)
        }
        guard LanSyncEncoding.constantTimeEquals(
            confirmation.proof,
            keys.confirmationProof(for: .host)
        ) else {
            throw LanSyncHandshakeFailure.keyConfirmationFailed
        }

        let reply = LanSyncKeyConfirmationReplyPayload(
            sessionID: keys.sessionID,
            signature: try localIdentity.sign(digest),
            proof: keys.confirmationProof(for: .guest)
        )
        let outgoing = try makeFrame(kind: .keyConfirmationReply, payloadValue: reply)
        peerVerificationPrompt = makePrompt(keys: keys)
        state = .awaitingUserVerification
        return outcome(frames: [outgoing])
    }

    private func hostHandleKeyConfirmationReply(_ frame: LanSyncFrame) throws -> LanSyncHandshakeOutcome {
        guard role == .host, state == .awaitingKeyConfirmationReply else {
            throw LanSyncHandshakeFailure.unexpectedFrame(kind: "keyConfirmationReply", state: stateName)
        }
        guard let reply = helloReplyPayload, let keys = sessionKeys, let digest = transcriptHash else {
            throw LanSyncHandshakeFailure.invalidState("缺少主机握手状态")
        }
        let confirmation: LanSyncKeyConfirmationReplyPayload = try decode(frame)
        guard confirmation.sessionID == keys.sessionID else {
            throw LanSyncHandshakeFailure.sessionMismatch
        }
        guard LanSyncDeviceIdentity.verifySignature(
            confirmation.signature,
            data: digest,
            publicKey: reply.signingPublicKey
        ) else {
            throw LanSyncHandshakeFailure.invalidSignature(peer: reply.displayName)
        }
        guard LanSyncEncoding.constantTimeEquals(
            confirmation.proof,
            keys.confirmationProof(for: .guest)
        ) else {
            throw LanSyncHandshakeFailure.keyConfirmationFailed
        }
        peerVerificationPrompt = makePrompt(keys: keys)
        state = .awaitingUserVerification
        return outcome(frames: [])
    }

    private func handleSessionConfirm(_ frame: LanSyncFrame) throws -> LanSyncHandshakeOutcome {
        switch state {
        case .awaitingUserVerification, .awaitingPeerConfirmation:
            break
        default:
            throw LanSyncHandshakeFailure.unexpectedFrame(kind: "sessionConfirm", state: stateName)
        }
        guard let keys = sessionKeys else {
            throw LanSyncHandshakeFailure.invalidState("缺少会话密钥")
        }
        let confirm: LanSyncSessionConfirmPayload = try decode(frame)
        guard confirm.sessionID == keys.sessionID else {
            throw LanSyncHandshakeFailure.sessionMismatch
        }
        let peerRole: LanSyncRole = role == .host ? .guest : .host
        guard LanSyncEncoding.constantTimeEquals(
            confirm.proof,
            keys.sessionConfirmProof(for: peerRole)
        ) else {
            throw LanSyncHandshakeFailure.userRejectedVerification
        }
        peerConfirmed = true
        var frames: [LanSyncFrame] = []
        if case .awaitingPeerConfirmation = state {
            state = .established
        } else if ownConfirmed {
            state = .established
        } else {
            // Peer confirmed first; keep waiting for the local user.
            frames = []
        }
        return outcome(frames: frames)
    }

    private func handlePeerError(_ frame: LanSyncFrame) throws -> LanSyncHandshakeOutcome {
        let payload: LanSyncErrorPayload = (try? decode(frame)) ?? LanSyncErrorPayload(
            code: "peer-error",
            message: "对方设备中止了配对。"
        )
        let failure = LanSyncHandshakeFailure.peerReportedError(
            code: payload.code,
            message: payload.message
        )
        state = .failed(failure)
        throw failure
    }

    // MARK: - Helpers

    private var stateName: String {
        switch state {
        case .idle: "idle"
        case .awaitingHelloReply: "awaitingHelloReply"
        case .awaitingKeyConfirmation: "awaitingKeyConfirmation"
        case .awaitingKeyConfirmationReply: "awaitingKeyConfirmationReply"
        case .awaitingUserVerification: "awaitingUserVerification"
        case .awaitingPeerConfirmation: "awaitingPeerConfirmation"
        case .established: "established"
        case .failed: "failed"
        }
    }

    private func outcome(
        frames: [LanSyncFrame],
        failure: LanSyncHandshakeFailure? = nil
    ) -> LanSyncHandshakeOutcome {
        LanSyncHandshakeOutcome(
            outgoingFrames: frames,
            state: state,
            verificationPrompt: peerVerificationPrompt,
            session: state == .established ? sessionKeys : nil,
            failure: failure
        )
    }

    private func makePrompt(keys: LanSyncSessionKeys) -> LanSyncVerificationPrompt {
        LanSyncVerificationPrompt(
            codeDisplay: keys.shortAuthenticationCodeDisplay,
            peerDisplayName: keys.peerDisplayName,
            peerDeviceID: keys.peerDeviceID,
            peerFingerprint: LanSyncEncoding.fingerprint(publicKey: keys.peerSigningPublicKey)
        )
    }

    private func makeFrame<Payload: Encodable>(
        kind: LanSyncFrameKind,
        payloadValue: Payload
    ) throws -> LanSyncFrame {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(payloadValue)
        let frame = LanSyncFrame(
            version: LanSyncProtocolSpec.version,
            kind: kind,
            sequence: outgoingSequence,
            payload: payload
        )
        outgoingSequence += 1
        return frame
    }

    private func decode<Payload: Decodable>(_ frame: LanSyncFrame) throws -> Payload {
        do {
            return try JSONDecoder().decode(Payload.self, from: frame.payload)
        } catch {
            throw LanSyncHandshakeFailure.malformedPayload
        }
    }

    private func validatePublicMaterial(_ signing: Data, _ ephemeral: Data) throws {
        guard signing.count == 32, ephemeral.count == 32 else {
            throw LanSyncHandshakeFailure.malformedPayload
        }
    }

    private func matches(
        expectedPeer: LanSyncExpectedPeer,
        deviceID: String,
        publicKey: Data
    ) -> Bool {
        deviceID == expectedPeer.deviceID
            && LanSyncEncoding.constantTimeEquals(publicKey, expectedPeer.signingPublicKey)
    }

    static func transcriptDigest(
        hello: LanSyncHelloPayload,
        reply: LanSyncHelloReplyPayload
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var unsignedReply = reply
        unsignedReply.signature = Data()
        do {
            var transcript = Data()
            transcript.append(try encoder.encode(hello))
            transcript.append(try encoder.encode(unsignedReply))
            return LanSyncEncoding.sha256(transcript)
        } catch {
            throw LanSyncHandshakeFailure.malformedPayload
        }
    }
}

extension LanSyncSessionKeys {
    func confirmationProof(for role: LanSyncRole) -> Data {
        LanSyncEncoding.hmacSHA256(
            key: sessionKey,
            data: Data("confirm:\(role.rawValue):".utf8) + transcriptHash
        )
    }

    func sessionConfirmProof(for role: LanSyncRole) -> Data {
        LanSyncEncoding.hmacSHA256(
            key: sessionKey,
            data: Data("session-confirm:\(role.rawValue):".utf8) + transcriptHash
        )
    }
}
