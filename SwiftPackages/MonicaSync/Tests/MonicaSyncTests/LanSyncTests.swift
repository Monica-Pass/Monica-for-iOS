import Foundation
import Testing
@testable import MonicaSync

// MARK: - Shared fixtures

private enum LanSyncTestFixtures {
    static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    static let laterDate = Date(timeIntervalSince1970: 1_700_003_600)

    static func identity(_ seed: String) throws -> LanSyncDeviceIdentity {
        try LanSyncDeviceIdentity(deterministicSeed: Data(seed.utf8))
    }

    static func note(
        syncID: UUID = UUID(),
        projectTitle: String = "Personal",
        title: String = "Example",
        favorite: Bool = false,
        body: String = "secret body"
    ) -> LanSyncItem {
        LanSyncItem(
            syncID: syncID,
            projectTitle: projectTitle,
            title: title,
            favorite: favorite,
            content: .note(LanSyncNoteContent(body: body))
        )
    }

    static func login(syncID: UUID = UUID(), username: String = "alice") -> LanSyncItem {
        LanSyncItem(
            syncID: syncID,
            projectTitle: "Work",
            title: "Login",
            favorite: true,
            content: .login(
                LanSyncLoginContent(
                    username: username,
                    password: "hunter2",
                    url: "https://example.com",
                    notes: "note"
                )
            )
        )
    }

    static func localItem(_ item: LanSyncItem, entryID: String = "local-entry-1") -> LanSyncLocalItem {
        LanSyncLocalItem(item: item, localEntryID: entryID)
    }

    static func baseItem(for item: LanSyncItem, localEntryID: String? = "local-entry-1") -> LanSyncMergeBaseItem {
        LanSyncMergeBaseItem(contentHash: item.contentHash, localEntryID: localEntryID, kind: item.kind)
    }

    static func makeBase(
        peerDeviceID: String = "peer-device-a",
        items: [(UUID, LanSyncMergeBaseItem)] = [],
        tombstones: [(UUID, LanSyncMergeBaseTombstone)] = []
    ) -> LanSyncMergeBase {
        var base = LanSyncMergeBase(peerDeviceID: peerDeviceID, lastSyncedAt: referenceDate)
        for (syncID, item) in items {
            base.setItem(item, for: syncID)
        }
        for (syncID, tombstone) in tombstones {
            base.setTombstone(tombstone, for: syncID)
        }
        return base
    }

    static func snapshot(
        items: [LanSyncItem] = [],
        tombstones: [LanSyncTombstone] = [],
        senderDeviceID: String = "peer-device-a"
    ) throws -> LanSyncVaultSnapshot {
        try LanSyncVaultSnapshot.make(
            vaultID: "vault-1",
            senderDeviceID: senderDeviceID,
            senderDisplayName: "Peer Device",
            revision: 7,
            exportedAt: referenceDate,
            items: items,
            tombstones: tombstones
        )
    }

    static func sessionKeys(
        role: LanSyncRole,
        seed: String,
        sessionID: String = "session-1"
    ) -> LanSyncSessionKeys {
        let sessionKey = LanSyncEncoding.hkdf(
            inputKeyMaterial: Data(seed.utf8),
            salt: Data("fixture-salt".utf8),
            info: Data("fixture-session".utf8),
            outputByteCount: 32
        )
        return LanSyncSessionKeys(
            sessionID: sessionID,
            role: role,
            peerDeviceID: role == .host ? "guest-device" : "host-device",
            peerDisplayName: role == .host ? "Guest Device" : "Host Device",
            peerSigningPublicKey: Data(repeating: 0x11, count: 32),
            transcriptHash: Data(repeating: 0x22, count: 32),
            sessionKey: sessionKey
        )
    }
}

// MARK: - Assertion helpers

private enum LanSyncTestError: Error, CustomStringConvertible {
    case handshakeDidNotComplete(String)

    var description: String {
        switch self {
        case .handshakeDidNotComplete(let detail):
            "handshake did not complete: \(detail)"
        }
    }
}

private func expectThrows<E: Error & Equatable>(
    _ expected: E,
    _ body: () throws -> Void
) {
    do {
        try body()
        Issue.record("Expected \(expected) but no error was thrown")
    } catch let error as E {
        #expect(error == expected)
    } catch {
        Issue.record("Expected \(expected) but a different error was thrown: \(error)")
    }
}

private func expectMalformedFrame(_ body: () throws -> Void) {
    do {
        try body()
        Issue.record("Expected LanSyncWireError.malformedFrame but no error was thrown")
    } catch let error as LanSyncWireError {
        guard case .malformedFrame = error else {
            Issue.record("Expected LanSyncWireError.malformedFrame, got \(error)")
            return
        }
    } catch {
        Issue.record("Expected LanSyncWireError.malformedFrame, got \(error)")
    }
}

// MARK: - Handshake drivers

private func makeHostHandshake(
    identitySeed: String = "host-identity",
    displayName: String = "Host Mac",
    pairingSecret: LanSyncPairingSecret = .shortCode("123456"),
    expectedPeer: LanSyncExpectedPeer? = nil,
    entropySeed: String = "host-entropy"
) throws -> LanSyncHandshake {
    LanSyncHandshake(
        role: .host,
        identity: try LanSyncTestFixtures.identity(identitySeed),
        displayName: displayName,
        pairingSecret: pairingSecret,
        expectedPeer: expectedPeer,
        entropy: LanSyncHandshakeEntropy(deterministicSeed: Data(entropySeed.utf8))
    )
}

private func makeGuestHandshake(
    identitySeed: String = "guest-identity",
    displayName: String = "Guest iPhone",
    pairingSecret: LanSyncPairingSecret = .shortCode("123456"),
    expectedPeer: LanSyncExpectedPeer? = nil,
    entropySeed: String = "guest-entropy"
) throws -> LanSyncHandshake {
    LanSyncHandshake(
        role: .guest,
        identity: try LanSyncTestFixtures.identity(identitySeed),
        displayName: displayName,
        pairingSecret: pairingSecret,
        expectedPeer: expectedPeer,
        entropy: LanSyncHandshakeEntropy(deterministicSeed: Data(entropySeed.utf8))
    )
}

private struct HandshakeCeremonyResult {
    let hostKeys: LanSyncSessionKeys
    let guestKeys: LanSyncSessionKeys
}

/// Drives both handshake state machines in a loop, exchanging `outgoingFrames`
/// and confirming the SAS as soon as each side asks the user to.
private func runHandshakeCeremony(
    host: LanSyncHandshake,
    guest: LanSyncHandshake,
    guestBeginsFirst: Bool = false
) throws -> HandshakeCeremonyResult {
    if guestBeginsFirst {
        _ = try guest.begin()
    }

    var toGuest = try host.begin().outgoingFrames
    var toHost: [LanSyncFrame] = []
    var hostKeys: LanSyncSessionKeys?
    var guestKeys: LanSyncSessionKeys?

    for _ in 0..<64 {
        if !toGuest.isEmpty {
            let frame = toGuest.removeFirst()
            let outcome = try guest.receive(frame)
            if let session = outcome.session { guestKeys = session }
            toHost.append(contentsOf: outcome.outgoingFrames)
            continue
        }
        if !toHost.isEmpty {
            let frame = toHost.removeFirst()
            let outcome = try host.receive(frame)
            if let session = outcome.session { hostKeys = session }
            toGuest.append(contentsOf: outcome.outgoingFrames)
            continue
        }
        if case .awaitingUserVerification = host.currentState {
            let outcome = host.confirmUserVerification(matches: true)
            if let session = outcome.session { hostKeys = session }
            toGuest.append(contentsOf: outcome.outgoingFrames)
            continue
        }
        if case .awaitingUserVerification = guest.currentState {
            let outcome = guest.confirmUserVerification(matches: true)
            if let session = outcome.session { guestKeys = session }
            toHost.append(contentsOf: outcome.outgoingFrames)
            continue
        }
        break
    }

    guard let hostKeys, let guestKeys else {
        throw LanSyncTestError.handshakeDidNotComplete(
            "host=\(host.currentState) guest=\(guest.currentState)"
        )
    }
    return HandshakeCeremonyResult(hostKeys: hostKeys, guestKeys: guestKeys)
}

/// Runs a host-initiated handshake up to (and including) the key-confirmation
/// exchange, leaving both sides in `.awaitingUserVerification`.
private func advanceToUserVerification(host: LanSyncHandshake, guest: LanSyncHandshake) throws {
    var toGuest = try host.begin().outgoingFrames
    var toHost: [LanSyncFrame] = []

    for _ in 0..<16 {
        if !toGuest.isEmpty {
            let frame = toGuest.removeFirst()
            toHost.append(contentsOf: try guest.receive(frame).outgoingFrames)
            continue
        }
        if !toHost.isEmpty {
            let frame = toHost.removeFirst()
            toGuest.append(contentsOf: try host.receive(frame).outgoingFrames)
            continue
        }
        break
    }

    guard case .awaitingUserVerification = host.currentState,
          case .awaitingUserVerification = guest.currentState
    else {
        throw LanSyncTestError.handshakeDidNotComplete(
            "expected awaitingUserVerification, host=\(host.currentState) guest=\(guest.currentState)"
        )
    }
}

// MARK: - Frame codec and stream decoder

@Suite("LanSync frame protocol")
struct LanSyncProtocolTests {
    @Test func frameCodecRoundTripsEveryKindAndPayload() throws {
        for kind in LanSyncFrameKind.allCases {
            let payload = Data("payload-for-\(kind.rawValue)".utf8)
            let frame = LanSyncFrame(kind: kind, sequence: 42, payload: payload)
            let encoded = try LanSyncFrameCodec.encode(frame)

            let header = [UInt8](encoded.prefix(LanSyncProtocolSpec.frameLengthHeaderBytes))
            let declaredLength = header.reduce(0) { ($0 << 8) | Int($1) }
            #expect(declaredLength == encoded.count - LanSyncProtocolSpec.frameLengthHeaderBytes)

            let body = Data(encoded.dropFirst(LanSyncProtocolSpec.frameLengthHeaderBytes))
            let decoded = try LanSyncFrameCodec.decode(body)
            #expect(decoded == frame)
            #expect(decoded.version == LanSyncProtocolSpec.version)
            #expect(decoded.kind == kind)
            #expect(decoded.sequence == 42)
            #expect(decoded.payload == payload)
        }

        #expect(LanSyncFrameKind.hello.isHandshakeFrame)
        #expect(LanSyncFrameKind.helloReply.isHandshakeFrame)
        #expect(LanSyncFrameKind.keyConfirmation.isHandshakeFrame)
        #expect(LanSyncFrameKind.keyConfirmationReply.isHandshakeFrame)
        #expect(LanSyncFrameKind.sessionConfirm.isHandshakeFrame)
        #expect(!LanSyncFrameKind.sealed.isHandshakeFrame)
        #expect(!LanSyncFrameKind.error.isHandshakeFrame)
    }

    @Test func decodeRejectsTruncatedBodyAndMalformedJSON() {
        expectMalformedFrame {
            _ = try LanSyncFrameCodec.decode(Data(#"{"version":1,"kind":"hello""#.utf8))
        }
        expectMalformedFrame {
            _ = try LanSyncFrameCodec.decode(Data("this is not json".utf8))
        }
        expectMalformedFrame {
            _ = try LanSyncFrameCodec.decode(Data())
        }
    }

    @Test func decodeRejectsUnknownKind() {
        let json = Data(#"{"version":1,"kind":"futureKind","sequence":1,"payload":""}"#.utf8)
        expectMalformedFrame {
            _ = try LanSyncFrameCodec.decode(json)
        }
    }

    @Test func decodeRejectsUnsupportedProtocolVersion() {
        let json = Data(#"{"version":2,"kind":"hello","sequence":1,"payload":""}"#.utf8)
        expectThrows(LanSyncWireError.unsupportedProtocolVersion(2)) {
            _ = try LanSyncFrameCodec.decode(json)
        }
    }

    @Test func decodeRejectsOversizedFrame() {
        let oversized = Data(count: LanSyncProtocolSpec.maxFrameBytes + 1)
        expectThrows(LanSyncWireError.frameTooLarge(LanSyncProtocolSpec.maxFrameBytes + 1)) {
            _ = try LanSyncFrameCodec.decode(oversized)
        }
    }

    @Test func streamDecoderHandlesByteByByteAndDeterministicRandomSplits() throws {
        let frames = [
            LanSyncFrame(kind: .hello, sequence: 1, payload: Data("hello".utf8)),
            LanSyncFrame(kind: .sealed, sequence: 1_001, payload: Data(repeating: 0xAB, count: 300)),
            LanSyncFrame(kind: .error, sequence: 9, payload: Data()),
        ]
        var stream = Data()
        for frame in frames {
            stream.append(try LanSyncFrameCodec.encode(frame))
        }

        var byteDecoder = LanSyncFrameStreamDecoder()
        var byteFrames: [LanSyncFrame] = []
        for byte in stream {
            byteFrames.append(contentsOf: try byteDecoder.append(Data([byte])))
        }
        #expect(byteFrames == frames)
        #expect(!byteDecoder.hasBufferedBytes)

        var randomDecoder = LanSyncFrameStreamDecoder()
        var randomFrames: [LanSyncFrame] = []
        var state: UInt64 = 0x0123_4567_89AB_CDEF
        var offset = 0
        while offset < stream.count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let chunkSize = Int((state >> 33) % 11) + 1
            let end = min(offset + chunkSize, stream.count)
            randomFrames.append(contentsOf: try randomDecoder.append(Data(stream[offset..<end])))
            offset = end
        }
        #expect(randomFrames == frames)
        #expect(!randomDecoder.hasBufferedBytes)
    }

    @Test func streamDecoderHandlesMultipleFramesInOneChunk() throws {
        let frames = [
            LanSyncFrame(kind: .hello, sequence: 1, payload: Data("one".utf8)),
            LanSyncFrame(kind: .sessionConfirm, sequence: 2, payload: Data("two".utf8)),
            LanSyncFrame(kind: .sealed, sequence: 3, payload: Data("three".utf8)),
        ]
        var stream = Data()
        for frame in frames {
            stream.append(try LanSyncFrameCodec.encode(frame))
        }

        var decoder = LanSyncFrameStreamDecoder()
        #expect(try decoder.append(stream) == frames)
        #expect(!decoder.hasBufferedBytes)
    }

    @Test func streamDecoderBuffersPartialFramesAndResetClearsBuffer() throws {
        let frame = LanSyncFrame(kind: .hello, sequence: 7, payload: Data("buffered".utf8))
        let encoded = try LanSyncFrameCodec.encode(frame)

        var decoder = LanSyncFrameStreamDecoder()
        let split = encoded.count / 2
        #expect(try decoder.append(Data(encoded.prefix(split))).isEmpty)
        #expect(decoder.hasBufferedBytes)
        #expect(try decoder.append(Data(encoded.dropFirst(split))) == [frame])
        #expect(!decoder.hasBufferedBytes)

        #expect(try decoder.append(Data(encoded.prefix(3))).isEmpty)
        #expect(decoder.hasBufferedBytes)
        decoder.reset()
        #expect(!decoder.hasBufferedBytes)
        #expect(try decoder.append(encoded) == [frame])
    }

    @Test func streamDecoderRejectsZeroLengthAndOversizedFrames() throws {
        var zeroDecoder = LanSyncFrameStreamDecoder()
        expectMalformedFrame {
            _ = try zeroDecoder.append(Data([0, 0, 0, 0]))
        }

        let frame = LanSyncFrame(kind: .hello, sequence: 1, payload: Data(repeating: 0xCD, count: 64))
        let encoded = try LanSyncFrameCodec.encode(frame)
        let bodyLength = encoded.count - LanSyncProtocolSpec.frameLengthHeaderBytes
        var tinyDecoder = LanSyncFrameStreamDecoder(maxFrameBytes: 16)
        expectThrows(LanSyncWireError.frameTooLarge(bodyLength)) {
            _ = try tinyDecoder.append(encoded)
        }
    }
}

// MARK: - Crypto and identity

@Suite("LanSync crypto and identity")
struct LanSyncCryptoTests {
    @Test func deterministicIdentityFromSameSeedIsStable() throws {
        let first = try LanSyncTestFixtures.identity("seed-alpha")
        let second = try LanSyncTestFixtures.identity("seed-alpha")

        #expect(first.deviceID == second.deviceID)
        #expect(first.fingerprint == second.fingerprint)
        #expect(first.signingPublicKey == second.signingPublicKey)
        #expect(first.agreementPublicKey == second.agreementPublicKey)
        #expect(first.exportPrivateMaterial() == second.exportPrivateMaterial())
        #expect(first.deviceID.count == 16)
    }

    @Test func differentSeedsProduceDifferentIdentities() throws {
        let first = try LanSyncTestFixtures.identity("seed-alpha")
        let second = try LanSyncTestFixtures.identity("seed-beta")

        #expect(first.deviceID != second.deviceID)
        #expect(first.fingerprint != second.fingerprint)
        #expect(first.signingPublicKey != second.signingPublicKey)
        #expect(first.exportPrivateMaterial() != second.exportPrivateMaterial())
    }

    @Test func identityPrivateMaterialExportRestoreRoundTrip() throws {
        let original = try LanSyncTestFixtures.identity("round-trip-seed")
        let restored = try LanSyncDeviceIdentity(privateMaterial: original.exportPrivateMaterial())

        #expect(restored.deviceID == original.deviceID)
        #expect(restored.fingerprint == original.fingerprint)
        #expect(restored.signingPublicKey == original.signingPublicKey)
        #expect(restored.agreementPublicKey == original.agreementPublicKey)

        let message = Data("payload to sign".utf8)
        let signature = try restored.sign(message)
        #expect(LanSyncDeviceIdentity.verifySignature(signature, data: message, publicKey: original.signingPublicKey))
    }

    @Test func invalidPrivateMaterialIsRejected() {
        expectThrows(LanSyncIdentityError.invalidPrivateMaterial) {
            _ = try LanSyncDeviceIdentity(privateMaterial: Data(repeating: 0, count: 63))
        }
        expectThrows(LanSyncIdentityError.invalidPrivateMaterial) {
            _ = try LanSyncDeviceIdentity(privateMaterial: Data())
        }
    }

    @Test func signAndVerifyRejectsTamperingAndWrongKey() throws {
        let signer = try LanSyncTestFixtures.identity("signer")
        let other = try LanSyncTestFixtures.identity("other")
        let message = Data("authentic message".utf8)
        let signature = try signer.sign(message)

        #expect(LanSyncDeviceIdentity.verifySignature(signature, data: message, publicKey: signer.signingPublicKey))
        #expect(!LanSyncDeviceIdentity.verifySignature(signature, data: Data("tampered message".utf8), publicKey: signer.signingPublicKey))
        #expect(!LanSyncDeviceIdentity.verifySignature(signature, data: message, publicKey: other.signingPublicKey))
        #expect(!LanSyncDeviceIdentity.verifySignature(Data(repeating: 0, count: 64), data: message, publicKey: signer.signingPublicKey))
    }

    @Test func hexAndBase64URLRoundTrip() throws {
        let data = Data([0x00, 0x01, 0x0F, 0xFF, 0xAB])
        #expect(LanSyncEncoding.hex(data) == "00010fffab")
        #expect(LanSyncEncoding.hex(Data()) == "")

        let encoded = LanSyncEncoding.base64URL(data)
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
        #expect(LanSyncEncoding.data(base64URL: encoded) == data)
        #expect(LanSyncEncoding.data(base64URL: "") == Data())
        #expect(LanSyncEncoding.data(base64URL: "!!!not-base64!!!") == nil)
    }

    @Test func constantTimeEqualsMatchesOnlyIdenticalBytes() {
        let value = Data([1, 2, 3, 4])
        #expect(LanSyncEncoding.constantTimeEquals(value, Data([1, 2, 3, 4])))
        #expect(!LanSyncEncoding.constantTimeEquals(value, Data([1, 2, 3, 5])))
        #expect(!LanSyncEncoding.constantTimeEquals(value, Data([1, 2, 3])))
        #expect(LanSyncEncoding.constantTimeEquals(Data(), Data()))
    }

    @Test func hkdfIsDeterministicAndDomainSeparated() {
        let input = Data("input key material".utf8)
        let salt = Data("salt".utf8)
        let info = Data("info".utf8)

        let first = LanSyncEncoding.hkdf(inputKeyMaterial: input, salt: salt, info: info, outputByteCount: 32)
        let second = LanSyncEncoding.hkdf(inputKeyMaterial: input, salt: salt, info: info, outputByteCount: 32)
        #expect(first == second)
        #expect(first.count == 32)

        let differentInfo = LanSyncEncoding.hkdf(inputKeyMaterial: input, salt: salt, info: Data("other-info".utf8), outputByteCount: 32)
        let differentSalt = LanSyncEncoding.hkdf(inputKeyMaterial: input, salt: Data("other-salt".utf8), info: info, outputByteCount: 32)
        let longerOutput = LanSyncEncoding.hkdf(inputKeyMaterial: input, salt: salt, info: info, outputByteCount: 64)
        #expect(first != differentInfo)
        #expect(first != differentSalt)
        // HKDF-Expand is a stream: a longer request shares the shorter request's prefix.
        #expect(first == Data(longerOutput.prefix(32)))
        #expect(longerOutput.count == 64)
    }

    @Test func sha256HmacAndFingerprintAreStable() throws {
        #expect(LanSyncEncoding.hex(LanSyncEncoding.sha256(Data("abc".utf8))) ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let key = Data("key".utf8)
        let message = Data("message".utf8)
        let mac = LanSyncEncoding.hmacSHA256(key: key, data: message)
        #expect(mac == LanSyncEncoding.hmacSHA256(key: key, data: message))
        #expect(mac != LanSyncEncoding.hmacSHA256(key: Data("other-key".utf8), data: message))
        #expect(mac.count == 32)

        let fingerprint = LanSyncEncoding.fingerprint(publicKey: Data([0xAB, 0xCD, 0xEF, 0x01, 0x23]))
        #expect(fingerprint == "ABCD EF01 23")
    }

    @Test func sessionKeyDerivedPropertiesAndSASDisplayAreStable() {
        let keys = LanSyncTestFixtures.sessionKeys(role: .host, seed: "session-seed")
        #expect(keys.shortAuthenticationCode.count == 6)
        let sasIsAllDigits = keys.shortAuthenticationCode.allSatisfy { $0.isNumber }
        #expect(sasIsAllDigits)
        #expect(keys.shortAuthenticationCodeDisplay.count == 7)
        #expect(keys.shortAuthenticationCodeDisplay.contains(" "))
        #expect(keys.sessionFingerprint.count == 16)
        #expect(keys.sessionFingerprint == LanSyncTestFixtures.sessionKeys(role: .host, seed: "session-seed").sessionFingerprint)
        #expect(keys.keyConfirmationProof().count == 32)
    }
}

// MARK: - Pairing secret

@Suite("LanSync pairing secret")
struct LanSyncPairingSecretTests {
    @Test func generateShortCodeProducesSixValidDigits() {
        for _ in 0..<32 {
            let secret = LanSyncPairingSecret.generateShortCode()
            guard case .shortCode(let code) = secret else {
                Issue.record("generateShortCode did not return a short code")
                return
            }
            #expect(code.count == LanSyncProtocolSpec.shortCodeDigits)
            let codeIsAllDigits = code.allSatisfy { $0.isNumber }
            #expect(codeIsAllDigits)
            #expect(LanSyncPairingSecret.validateShortCode(code))
            #expect(secret.kind == .shortCode)
        }
    }

    @Test func normalizedCodeStripsSpacesAndHyphensAndValidationRejectsInvalidCodes() {
        #expect(LanSyncPairingSecret.normalizedCode("12 34-56") == "123456")
        #expect(LanSyncPairingSecret.normalizedCode(" 123 456 ") == "123456")
        #expect(LanSyncPairingSecret.validateShortCode("12 34-56"))
        #expect(!LanSyncPairingSecret.validateShortCode("12345"))
        #expect(!LanSyncPairingSecret.validateShortCode("1234567"))
        #expect(!LanSyncPairingSecret.validateShortCode("abcdef"))
        #expect(!LanSyncPairingSecret.validateShortCode(""))
    }

    @Test func generateQRTokenProduces32Bytes() {
        let secret = LanSyncPairingSecret.generateQRToken()
        guard case .qrToken(let token) = secret else {
            Issue.record("generateQRToken did not return a QR token")
            return
        }
        #expect(token.count == 32)
        #expect(secret.kind == .qrToken)
    }

    @Test func kdfInputIsDomainSeparatedAndNormalizesShortCodes() {
        let plain = LanSyncPairingSecret.shortCode("123456")
        let spaced = LanSyncPairingSecret.shortCode("12 34-56")
        let token = LanSyncPairingSecret.qrToken(Data("123456".utf8))

        #expect(plain.kdfInput == spaced.kdfInput)
        #expect(plain.kdfInput.prefix(5) == Data("code:".utf8))
        #expect(plain.kdfInput.suffix(6) == Data("123456".utf8))
        #expect(token.kdfInput.prefix(3) == Data("qr:".utf8))
        #expect(plain.kdfInput != token.kdfInput)
        #expect(plain.kind == .shortCode)
        #expect(token.kind == .qrToken)
    }
}

// MARK: - Handshake

@Suite("LanSync handshake ceremony")
struct LanSyncHandshakeTests {
    @Test func hostInitiatedCeremonyEstablishesBothSides() throws {
        let hostIdentity = try LanSyncTestFixtures.identity("host-identity")
        let guestIdentity = try LanSyncTestFixtures.identity("guest-identity")
        let host = try makeHostHandshake()
        let guest = try makeGuestHandshake()

        let result = try runHandshakeCeremony(host: host, guest: guest)

        #expect(host.currentState == .established)
        #expect(guest.currentState == .established)
        #expect(result.hostKeys.sessionID == result.guestKeys.sessionID)
        #expect(result.hostKeys.shortAuthenticationCode == result.guestKeys.shortAuthenticationCode)
        #expect(result.hostKeys.sessionFingerprint == result.guestKeys.sessionFingerprint)
        #expect(result.hostKeys.transcriptHash == result.guestKeys.transcriptHash)
        #expect(result.hostKeys.peerDeviceID == guestIdentity.deviceID)
        #expect(result.guestKeys.peerDeviceID == hostIdentity.deviceID)
        #expect(result.hostKeys.peerDisplayName == "Guest iPhone")
        #expect(result.guestKeys.peerDisplayName == "Host Mac")
        #expect(result.hostKeys.role == .host)
        #expect(result.guestKeys.role == .guest)
        #expect(host.verificationPrompt?.codeDisplay == guest.verificationPrompt?.codeDisplay)
        #expect(host.verificationPrompt?.peerDeviceID == guestIdentity.deviceID)
        #expect(guest.verificationPrompt?.peerDeviceID == hostIdentity.deviceID)
    }

    @Test func guestBeginReturnsNoFramesAndGuestPathCompletes() throws {
        let host = try makeHostHandshake()
        let guest = try makeGuestHandshake()

        let guestStart = try guest.begin()
        #expect(guestStart.outgoingFrames.isEmpty)
        #expect(guestStart.state == .idle)
        #expect(guest.currentState == .idle)

        let result = try runHandshakeCeremony(host: host, guest: guest, guestBeginsFirst: true)
        #expect(host.currentState == .established)
        #expect(guest.currentState == .established)
        #expect(result.hostKeys.shortAuthenticationCode == result.guestKeys.shortAuthenticationCode)
    }

    @Test func sessionConfirmIsRequiredFromBothUsersBeforeEstablishing() throws {
        let host = try makeHostHandshake()
        let guest = try makeGuestHandshake()
        try advanceToUserVerification(host: host, guest: guest)

        let hostConfirmation = host.confirmUserVerification(matches: true)
        #expect(hostConfirmation.state == .awaitingPeerConfirmation)
        #expect(hostConfirmation.session == nil)
        #expect(hostConfirmation.outgoingFrames.count == 1)
        #expect(hostConfirmation.outgoingFrames.first?.kind == .sessionConfirm)
        #expect(host.currentState == .awaitingPeerConfirmation)
        #expect(guest.currentState == .awaitingUserVerification)

        // The peer's sessionConfirm alone must not establish the guest; it still
        // has to confirm locally.
        let guestReceive = try guest.receive(try #require(hostConfirmation.outgoingFrames.first))
        #expect(guestReceive.session == nil)
        #expect(guest.currentState == .awaitingUserVerification)

        let guestConfirmation = guest.confirmUserVerification(matches: true)
        #expect(guestConfirmation.state == .established)
        #expect(guestConfirmation.session != nil)
        #expect(guestConfirmation.outgoingFrames.first?.kind == .sessionConfirm)

        _ = try host.receive(try #require(guestConfirmation.outgoingFrames.first))
        #expect(host.currentState == .established)
    }

    @Test func wrongPairingCodeFailsKeyConfirmation() throws {
        let host = try makeHostHandshake(pairingSecret: .shortCode("123456"))
        let guest = try makeGuestHandshake(pairingSecret: .shortCode("654321"))

        let hello = try #require(try host.begin().outgoingFrames.first)
        let helloReply = try #require(try guest.receive(hello).outgoingFrames.first)
        let keyConfirmation = try #require(try host.receive(helloReply).outgoingFrames.first)
        #expect(keyConfirmation.kind == .keyConfirmation)

        expectThrows(LanSyncHandshakeFailure.keyConfirmationFailed) {
            _ = try guest.receive(keyConfirmation)
        }
        #expect(guest.currentState == .failed(.keyConfirmationFailed))
    }

    @Test func tamperedHelloReplySignatureIsRejected() throws {
        let host = try makeHostHandshake()
        let guest = try makeGuestHandshake()

        let hello = try #require(try host.begin().outgoingFrames.first)
        let replyFrame = try #require(try guest.receive(hello).outgoingFrames.first)
        var reply = try JSONDecoder().decode(LanSyncHelloReplyPayload.self, from: replyFrame.payload)
        var signature = reply.signature
        signature[signature.startIndex] ^= 0xFF
        reply.signature = signature
        let tampered = LanSyncFrame(
            kind: .helloReply,
            sequence: replyFrame.sequence,
            payload: try JSONEncoder().encode(reply)
        )

        expectThrows(LanSyncHandshakeFailure.invalidSignature(peer: "Guest iPhone")) {
            _ = try host.receive(tampered)
        }
        #expect(host.currentState == .failed(.invalidSignature(peer: "Guest iPhone")))
    }

    @Test func protocolVersionMismatchesAreRejected() throws {
        // Frame-level version mismatch is rejected before any payload decoding.
        let host = try makeHostHandshake()
        let guest = try makeGuestHandshake()
        let hello = try #require(try host.begin().outgoingFrames.first)
        let futureFrame = LanSyncFrame(
            version: LanSyncProtocolSpec.version + 1,
            kind: hello.kind,
            sequence: hello.sequence,
            payload: hello.payload
        )
        expectThrows(LanSyncHandshakeFailure.unsupportedProtocolVersion(expected: 1, received: 2)) {
            _ = try guest.receive(futureFrame)
        }

        // Payload-level version mismatch is rejected by the hello handler.
        let otherGuest = try makeGuestHandshake()
        var helloPayload = try JSONDecoder().decode(LanSyncHelloPayload.self, from: hello.payload)
        helloPayload.version = LanSyncProtocolSpec.version + 1
        let mismatchedPayloadFrame = LanSyncFrame(
            kind: .hello,
            sequence: hello.sequence,
            payload: try JSONEncoder().encode(helloPayload)
        )
        expectThrows(LanSyncHandshakeFailure.unsupportedProtocolVersion(expected: 1, received: 2)) {
            _ = try otherGuest.receive(mismatchedPayloadFrame)
        }
    }

    @Test func replayedHandshakeSequenceIsRejected() throws {
        let host = try makeHostHandshake()
        let guest = try makeGuestHandshake()
        let hello = try #require(try host.begin().outgoingFrames.first)

        _ = try guest.receive(hello)
        expectThrows(LanSyncHandshakeFailure.replayedSequence(expected: 2, received: 1)) {
            _ = try guest.receive(hello)
        }
        #expect(guest.currentState == .failed(.replayedSequence(expected: 2, received: 1)))
    }

    @Test func expectedPeerWithDifferentSigningKeyIsRejected() throws {
        let stranger = try LanSyncTestFixtures.identity("stranger")
        let expectedPeer = LanSyncExpectedPeer(
            deviceID: stranger.deviceID,
            signingPublicKey: stranger.signingPublicKey,
            displayName: "Stranger"
        )
        let host = try makeHostHandshake(expectedPeer: expectedPeer)
        let guest = try makeGuestHandshake()

        let hello = try #require(try host.begin().outgoingFrames.first)
        let reply = try #require(try guest.receive(hello).outgoingFrames.first)
        expectThrows(LanSyncHandshakeFailure.identityMismatch) {
            _ = try host.receive(reply)
        }
        #expect(host.currentState == .failed(.identityMismatch))
    }

    @Test func userRejectionFailsVerificationAndNotifiesPeer() throws {
        let host = try makeHostHandshake()
        let guest = try makeGuestHandshake()
        try advanceToUserVerification(host: host, guest: guest)

        let rejection = host.confirmUserVerification(matches: false)
        #expect(rejection.failure == .userRejectedVerification)
        #expect(host.currentState == .failed(.userRejectedVerification))
        let errorFrame = try #require(rejection.outgoingFrames.first)
        #expect(errorFrame.kind == .error)

        do {
            _ = try guest.receive(errorFrame)
            Issue.record("Expected peerReportedError from the error frame")
        } catch let failure as LanSyncHandshakeFailure {
            if case .peerReportedError(let code, _) = failure {
                #expect(code == "user-rejected")
            } else {
                Issue.record("Unexpected handshake failure: \(failure)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        if case .failed(.peerReportedError(let code, _)) = guest.currentState {
            #expect(code == "user-rejected")
        } else {
            Issue.record("Guest did not fail with peerReportedError: \(guest.currentState)")
        }
    }

    @Test func beginTwiceAndConfirmInWrongStateReturnInvalidState() throws {
        let host = try makeHostHandshake()
        _ = try host.begin()
        expectThrows(LanSyncHandshakeFailure.invalidState("begin 只能调用一次")) {
            _ = try host.begin()
        }
        #expect(host.currentState == .awaitingHelloReply)

        let freshHost = try makeHostHandshake()
        let outcome = freshHost.confirmUserVerification(matches: true)
        #expect(outcome.failure == .invalidState("当前不在等待用户确认校验码"))
        #expect(freshHost.currentState == .failed(.invalidState("当前不在等待用户确认校验码")))
    }

    @Test func unexpectedFrameInWrongStateIsRejected() throws {
        let host = try makeHostHandshake()
        let hello = try #require(try host.begin().outgoingFrames.first)
        expectThrows(LanSyncHandshakeFailure.unexpectedFrame(kind: "hello", state: "awaitingHelloReply")) {
            _ = try host.receive(hello)
        }
        #expect(host.currentState == .failed(.unexpectedFrame(kind: "hello", state: "awaitingHelloReply")))
    }

    @Test func sessionIDMismatchIsRejected() throws {
        let host = try makeHostHandshake()
        let guest = try makeGuestHandshake()
        let hello = try #require(try host.begin().outgoingFrames.first)
        let replyFrame = try #require(try guest.receive(hello).outgoingFrames.first)

        var reply = try JSONDecoder().decode(LanSyncHelloReplyPayload.self, from: replyFrame.payload)
        reply.sessionID = "a-different-session"
        let mismatched = LanSyncFrame(
            kind: .helloReply,
            sequence: replyFrame.sequence,
            payload: try JSONEncoder().encode(reply)
        )
        expectThrows(LanSyncHandshakeFailure.sessionMismatch) {
            _ = try host.receive(mismatched)
        }
    }

    @Test func malformedPayloadsAndPairingKindMismatchAreRejected() throws {
        let guest = try makeGuestHandshake()
        let malformedHello = LanSyncFrame(kind: .hello, sequence: 1, payload: Data("garbage".utf8))
        expectThrows(LanSyncHandshakeFailure.malformedPayload) {
            _ = try guest.receive(malformedHello)
        }

        let qrGuest = try makeGuestHandshake(pairingSecret: .qrToken(Data(repeating: 0x42, count: 32)))
        let host = try makeHostHandshake(pairingSecret: .shortCode("123456"))
        let hello = try #require(try host.begin().outgoingFrames.first)
        expectThrows(
            LanSyncHandshakeFailure.pairingSecretKindMismatch(expected: .qrToken, received: .shortCode)
        ) {
            _ = try qrGuest.receive(hello)
        }
    }
}

// MARK: - Secure channel

@Suite("LanSync secure channel")
struct LanSyncSecureChannelTests {
    private func makeChannelPair(seed: String = "shared-session") -> (host: LanSyncSecureChannel, guest: LanSyncSecureChannel) {
        let hostKeys = LanSyncTestFixtures.sessionKeys(role: .host, seed: seed)
        let guestKeys = LanSyncTestFixtures.sessionKeys(role: .guest, seed: seed)
        return (hostKeys.makeSecureChannel(), guestKeys.makeSecureChannel())
    }

    @Test func sealOpenRoundTripsEveryMessageKind() throws {
        let channels = makeChannelPair()
        let kinds: [LanSyncSecureMessageKind] = [.snapshot, .receipt, .error, .syncComplete]

        for (index, kind) in kinds.enumerated() {
            let message = LanSyncSecureMessage(
                kind: kind,
                payload: Data("secure-payload-\(index)".utf8)
            )
            let frame = try channels.host.seal(message)
            #expect(frame.kind == .sealed)
            #expect(frame.sequence == 1_001 + UInt64(index))
            #expect(try channels.guest.open(frame) == message)
        }
        #expect(channels.host.sentFrameCount == 4)
        #expect(channels.guest.receivedFrameCount == 4)
    }

    @Test func hostAndGuestCanSealInBothDirections() throws {
        let channels = makeChannelPair()
        let hostMessage = LanSyncSecureMessage(kind: .snapshot, payload: Data("host->guest".utf8))
        let guestMessage = LanSyncSecureMessage(kind: .receipt, payload: Data("guest->host".utf8))

        #expect(try channels.guest.open(try channels.host.seal(hostMessage)) == hostMessage)
        #expect(try channels.host.open(try channels.guest.seal(guestMessage)) == guestMessage)
    }

    @Test func outOfOrderAndDuplicateSequencesAreRejected() throws {
        let channels = makeChannelPair()
        let first = LanSyncSecureMessage(kind: .snapshot, payload: Data("first".utf8))
        let second = LanSyncSecureMessage(kind: .snapshot, payload: Data("second".utf8))
        let firstFrame = try channels.host.seal(first)
        let secondFrame = try channels.host.seal(second)

        expectThrows(LanSyncWireError.replayedSequence(expected: 1_001, received: 1_002)) {
            _ = try channels.guest.open(secondFrame)
        }
        #expect(try channels.guest.open(firstFrame) == first)
        expectThrows(LanSyncWireError.replayedSequence(expected: 1_002, received: 1_001)) {
            _ = try channels.guest.open(firstFrame)
        }
        #expect(try channels.guest.open(secondFrame) == second)
    }

    @Test func tamperedCiphertextFailsAuthentication() throws {
        let channels = makeChannelPair()
        let message = LanSyncSecureMessage(kind: .snapshot, payload: Data("secret".utf8))
        var frame = try channels.host.seal(message)
        frame.payload[frame.payload.startIndex] ^= 0xFF

        expectThrows(LanSyncWireError.authenticationFailed) {
            _ = try channels.guest.open(frame)
        }
    }

    @Test func unrelatedChannelCannotOpenAnotherChannelFrames() throws {
        let channels = makeChannelPair(seed: "session-one")
        let unrelatedKeys = LanSyncTestFixtures.sessionKeys(role: .guest, seed: "session-two")
        let unrelated = unrelatedKeys.makeSecureChannel()
        let message = LanSyncSecureMessage(kind: .error, payload: Data("private".utf8))
        let frame = try channels.host.seal(message)

        expectThrows(LanSyncWireError.authenticationFailed) {
            _ = try unrelated.open(frame)
        }
    }

    @Test func countersStartAtZeroAndNonSealedFramesAreRejected() throws {
        let hostKeys = LanSyncTestFixtures.sessionKeys(role: .host, seed: "counters")
        let channel = hostKeys.makeSecureChannel()
        #expect(channel.sentFrameCount == 0)
        #expect(channel.receivedFrameCount == 0)

        _ = try channel.seal(LanSyncSecureMessage(kind: .snapshot, payload: Data()))
        #expect(channel.sentFrameCount == 1)

        let hello = LanSyncFrame(kind: .hello, sequence: 1, payload: Data())
        expectThrows(LanSyncWireError.unexpectedFrameKind(expected: "sealed", received: .hello)) {
            _ = try channel.open(hello)
        }
    }
}

// MARK: - Snapshot

@Suite("LanSync snapshot")
struct LanSyncSnapshotTests {
    @Test func contentHashIsStableAndChangesWithEveryField() throws {
        let syncID = UUID()
        let base = LanSyncTestFixtures.note(syncID: syncID, title: "Title", body: "Body")
        let same = LanSyncTestFixtures.note(syncID: syncID, title: "Title", body: "Body")
        #expect(base.contentHash == same.contentHash)
        #expect(try base.canonicalBytes() == same.canonicalBytes())
        #expect(base.contentHash.count == 32)

        let variants: [LanSyncItem] = [
            LanSyncTestFixtures.note(syncID: syncID, projectTitle: "Other", title: "Title", body: "Body"),
            LanSyncTestFixtures.note(syncID: syncID, title: "Other title", body: "Body"),
            LanSyncTestFixtures.note(syncID: syncID, title: "Title", favorite: true, body: "Body"),
            LanSyncTestFixtures.note(syncID: syncID, title: "Title", body: "Other body"),
            LanSyncTestFixtures.note(syncID: UUID(), title: "Title", body: "Body"),
            LanSyncTestFixtures.login(syncID: syncID),
        ]
        for variant in variants {
            #expect(variant.contentHash != base.contentHash)
        }
    }

    @Test func itemContentCodableRoundTripsAllKinds() throws {
        let contents: [LanSyncItemContent] = [
            .login(LanSyncLoginContent(username: "alice", password: "pw", url: "https://a.example", notes: "n")),
            .totp(
                LanSyncTotpContent(
                    secret: "JBSWY3DPEHPK3PXP",
                    issuer: "Example",
                    accountName: "alice@example.com",
                    period: 30,
                    digits: 6,
                    algorithm: "SHA1",
                    otpType: "totp",
                    counter: 0
                )
            ),
            .note(LanSyncNoteContent(body: "hello")),
            .card(
                LanSyncCardContent(
                    cardholderName: "Alice",
                    number: "4111111111111111",
                    expiryMonth: "12",
                    expiryYear: "2030",
                    securityCode: "123",
                    brand: "Visa",
                    notes: "note"
                )
            ),
        ]

        for content in contents {
            let data = try JSONEncoder().encode(content)
            let decoded = try JSONDecoder().decode(LanSyncItemContent.self, from: data)
            #expect(decoded == content)
            #expect(decoded.kind == content.kind)
        }
    }

    @Test func makeProducesValidDigest() throws {
        let items = [LanSyncTestFixtures.note(), LanSyncTestFixtures.login()]
        let tombstones = [LanSyncTombstone(syncID: UUID(), deletedAt: LanSyncTestFixtures.referenceDate)]
        let snapshot = try LanSyncTestFixtures.snapshot(items: items, tombstones: tombstones)

        #expect(snapshot.formatVersion == LanSyncProtocolSpec.snapshotFormatVersion)
        #expect(snapshot.digest.count == 32)
        #expect(snapshot.hasValidDigest)
        try snapshot.verifyIntegrity()
        #expect(try snapshot.computedDigest() == snapshot.digest)
        #expect(try snapshot.computedDigest() == snapshot.computedDigest())
    }

    @Test func tamperedItemOrDigestIsDetected() throws {
        let snapshot = try LanSyncTestFixtures.snapshot(items: [LanSyncTestFixtures.note()])

        var itemTampered = snapshot
        itemTampered.items[0].title = "Tampered"
        #expect(!itemTampered.hasValidDigest)
        expectThrows(LanSyncSnapshotError.digestMismatch) {
            try itemTampered.verifyIntegrity()
        }

        var digestTampered = snapshot
        digestTampered.digest[digestTampered.digest.startIndex] ^= 0xFF
        #expect(!digestTampered.hasValidDigest)
        expectThrows(LanSyncSnapshotError.digestMismatch) {
            try digestTampered.verifyIntegrity()
        }
    }

    @Test func duplicateSyncIDIsRejected() throws {
        let syncID = UUID()
        let first = LanSyncTestFixtures.note(syncID: syncID)
        let second = LanSyncTestFixtures.note(syncID: syncID, title: "Duplicate")

        expectThrows(LanSyncSnapshotError.duplicateSyncID(syncID)) {
            _ = try LanSyncTestFixtures.snapshot(items: [first, second])
        }
        expectThrows(LanSyncSnapshotError.duplicateSyncID(syncID)) {
            _ = try LanSyncTestFixtures.snapshot(
                items: [first],
                tombstones: [LanSyncTombstone(syncID: syncID, deletedAt: LanSyncTestFixtures.referenceDate)]
            )
        }
    }

    @Test func unsupportedFormatVersionIsRejected() throws {
        var snapshot = try LanSyncTestFixtures.snapshot(items: [LanSyncTestFixtures.note()])
        snapshot.formatVersion = LanSyncProtocolSpec.snapshotFormatVersion + 1
        expectThrows(LanSyncSnapshotError.unsupportedFormatVersion(LanSyncProtocolSpec.snapshotFormatVersion + 1)) {
            try snapshot.validate()
        }
    }

    @Test func snapshotCodableRoundTrips() throws {
        let snapshot = try LanSyncTestFixtures.snapshot(
            items: [LanSyncTestFixtures.note(), LanSyncTestFixtures.login()],
            tombstones: [LanSyncTombstone(syncID: UUID(), deletedAt: LanSyncTestFixtures.laterDate, deletedContentHash: Data([1, 2, 3]))]
        )
        let decoded = try JSONDecoder().decode(
            LanSyncVaultSnapshot.self,
            from: try JSONEncoder().encode(snapshot)
        )
        #expect(decoded == snapshot)
        #expect(decoded.hasValidDigest)
        try decoded.verifyIntegrity()
    }
}

// MARK: - Merge engine

@Suite("LanSync merge engine")
struct LanSyncMergeTests {
    private let engine = LanSyncMergeEngine()

    @Test func newRemoteItemCreates() throws {
        let item = LanSyncTestFixtures.note(title: "New")
        let result = engine.merge(
            remote: try LanSyncTestFixtures.snapshot(items: [item]),
            localItems: [],
            localTombstones: [],
            base: nil,
            now: LanSyncTestFixtures.referenceDate
        )

        #expect(result.actions == [.create(item: item)])
        #expect(result.conflicts.isEmpty)
        #expect(result.summary == LanSyncMergeSummary(created: 1, updated: 0, deleted: 0, conflicts: 0))
        #expect(result.base.item(for: item.syncID)?.contentHash == item.contentHash)
        #expect(result.base.item(for: item.syncID)?.localEntryID == nil)
    }

    @Test func remoteChangeWithLocalUnchangedUpdates() throws {
        let syncID = UUID()
        let old = LanSyncTestFixtures.note(syncID: syncID, title: "Old", body: "old")
        let new = LanSyncTestFixtures.note(syncID: syncID, title: "New", body: "new")
        let base = LanSyncTestFixtures.makeBase(items: [(syncID, LanSyncTestFixtures.baseItem(for: old))])

        let result = engine.merge(
            remote: try LanSyncTestFixtures.snapshot(items: [new]),
            localItems: [LanSyncTestFixtures.localItem(old, entryID: "entry-1")],
            localTombstones: [],
            base: base,
            now: LanSyncTestFixtures.referenceDate
        )

        #expect(result.actions == [.update(item: new, localEntryID: "entry-1")])
        #expect(result.conflicts.isEmpty)
        #expect(result.summary.updated == 1)
        #expect(result.base.item(for: syncID)?.contentHash == new.contentHash)
        #expect(result.base.item(for: syncID)?.localEntryID == "entry-1")
    }

    @Test func remoteUnchangedWithLocalChangeKeepsLocalWithoutAction() throws {
        let syncID = UUID()
        let old = LanSyncTestFixtures.note(syncID: syncID, title: "Old", body: "old")
        let localEdit = LanSyncTestFixtures.note(syncID: syncID, title: "Old", body: "local edit")
        let base = LanSyncTestFixtures.makeBase(items: [(syncID, LanSyncTestFixtures.baseItem(for: old))])

        let result = engine.merge(
            remote: try LanSyncTestFixtures.snapshot(items: [old]),
            localItems: [LanSyncTestFixtures.localItem(localEdit, entryID: "entry-1")],
            localTombstones: [],
            base: base,
            now: LanSyncTestFixtures.referenceDate
        )

        #expect(result.actions.isEmpty)
        #expect(result.conflicts.isEmpty)
        #expect(result.base.item(for: syncID)?.contentHash == old.contentHash)
        #expect(result.base.item(for: syncID)?.localEntryID == "entry-1")
    }

    @Test func bothModifiedDifferentlyProducesBothModifiedConflict() throws {
        let syncID = UUID()
        let old = LanSyncTestFixtures.note(syncID: syncID, title: "Old", body: "old")
        let localEdit = LanSyncTestFixtures.note(syncID: syncID, title: "Old", body: "local edit")
        let remoteEdit = LanSyncTestFixtures.note(syncID: syncID, title: "Old", body: "remote edit")
        let base = LanSyncTestFixtures.makeBase(items: [(syncID, LanSyncTestFixtures.baseItem(for: old))])

        let result = engine.merge(
            remote: try LanSyncTestFixtures.snapshot(items: [remoteEdit]),
            localItems: [LanSyncTestFixtures.localItem(localEdit, entryID: "entry-1")],
            localTombstones: [],
            base: base,
            now: LanSyncTestFixtures.referenceDate
        )

        #expect(result.actions.isEmpty)
        #expect(result.conflicts.count == 1)
        let conflict = try #require(result.conflicts.first)
        #expect(conflict.syncID == syncID)
        #expect(conflict.reason == .bothModified)
        #expect(conflict.localEntryID == "entry-1")
        #expect(conflict.localContentHash == localEdit.contentHash)
        #expect(conflict.remoteContentHash == remoteEdit.contentHash)
        // The remote version is not applied and the base stays at the ancestor.
        #expect(result.base.item(for: syncID)?.contentHash == old.contentHash)
    }

    @Test func bothChangedToIdenticalContentConverges() throws {
        let syncID = UUID()
        let old = LanSyncTestFixtures.note(syncID: syncID, title: "Old", body: "old")
        let sameEdit = LanSyncTestFixtures.note(syncID: syncID, title: "Old", body: "same edit")
        let base = LanSyncTestFixtures.makeBase(items: [(syncID, LanSyncTestFixtures.baseItem(for: old))])

        let result = engine.merge(
            remote: try LanSyncTestFixtures.snapshot(items: [sameEdit]),
            localItems: [LanSyncTestFixtures.localItem(sameEdit, entryID: "entry-1")],
            localTombstones: [],
            base: base,
            now: LanSyncTestFixtures.referenceDate
        )

        #expect(result.actions.isEmpty)
        #expect(result.conflicts.isEmpty)
        #expect(result.base.item(for: syncID)?.contentHash == sameEdit.contentHash)
    }

    @Test func remoteTombstoneDeletesLocalItemMatchingBase() throws {
        let syncID = UUID()
        let item = LanSyncTestFixtures.note(syncID: syncID)
        let base = LanSyncTestFixtures.makeBase(items: [(syncID, LanSyncTestFixtures.baseItem(for: item))])
        let tombstone = LanSyncTombstone(
            syncID: syncID,
            deletedAt: LanSyncTestFixtures.laterDate,
            deletedContentHash: item.contentHash
        )

        let result = engine.merge(
            remote: try LanSyncTestFixtures.snapshot(tombstones: [tombstone]),
            localItems: [LanSyncTestFixtures.localItem(item, entryID: "entry-1")],
            localTombstones: [],
            base: base,
            now: LanSyncTestFixtures.referenceDate
        )

        #expect(result.actions == [.delete(syncID: syncID, localEntryID: "entry-1")])
        #expect(result.conflicts.isEmpty)
        #expect(result.base.tombstone(for: syncID)?.lastContentHash == item.contentHash)
    }

    @Test func remoteTombstoneWithLocallyModifiedItemConflicts() throws {
        let syncID = UUID()
        let baseItem = LanSyncTestFixtures.note(syncID: syncID, title: "Old", body: "old")
        let localEdit = LanSyncTestFixtures.note(syncID: syncID, title: "Old", body: "local edit")
        let base = LanSyncTestFixtures.makeBase(items: [(syncID, LanSyncTestFixtures.baseItem(for: baseItem))])
        let tombstone = LanSyncTombstone(
            syncID: syncID,
            deletedAt: LanSyncTestFixtures.laterDate,
            deletedContentHash: baseItem.contentHash
        )

        let result = engine.merge(
            remote: try LanSyncTestFixtures.snapshot(tombstones: [tombstone]),
            localItems: [LanSyncTestFixtures.localItem(localEdit, entryID: "entry-1")],
            localTombstones: [],
            base: base,
            now: LanSyncTestFixtures.referenceDate
        )

        #expect(result.actions.isEmpty)
        let conflict = try #require(result.conflicts.first)
        #expect(conflict.reason == .remoteDeletedLocalModified)
        #expect(conflict.localContentHash == localEdit.contentHash)
        #expect(conflict.remoteContentHash == baseItem.contentHash)
        #expect(result.base.item(for: syncID)?.contentHash == baseItem.contentHash)
    }

    @Test func localTombstonePreventsResurrectionWhenRemoteUnchanged() throws {
        let syncID = UUID()
        let item = LanSyncTestFixtures.note(syncID: syncID)
        let base = LanSyncTestFixtures.makeBase(items: [(syncID, LanSyncTestFixtures.baseItem(for: item))])
        let localTombstone = LanSyncTombstone(
            syncID: syncID,
            deletedAt: LanSyncTestFixtures.laterDate,
            deletedContentHash: item.contentHash
        )

        let result = engine.merge(
            remote: try LanSyncTestFixtures.snapshot(items: [item]),
            localItems: [],
            localTombstones: [localTombstone],
            base: base,
            now: LanSyncTestFixtures.referenceDate
        )

        #expect(result.actions.isEmpty)
        #expect(result.conflicts.isEmpty)
        #expect(result.base.item(for: syncID)?.contentHash == item.contentHash)
    }

    @Test func remoteItemAfterAgreedTombstoneConflicts() throws {
        let syncID = UUID()
        let resurrection = LanSyncTestFixtures.note(syncID: syncID, title: "Resurrected")
        let baseTombstone = LanSyncMergeBaseTombstone(
            deletedAt: LanSyncTestFixtures.referenceDate,
            lastContentHash: Data([1, 2, 3])
        )
        let base = LanSyncTestFixtures.makeBase(tombstones: [(syncID, baseTombstone)])

        let result = engine.merge(
            remote: try LanSyncTestFixtures.snapshot(items: [resurrection]),
            localItems: [],
            localTombstones: [],
            base: base,
            now: LanSyncTestFixtures.referenceDate
        )

        #expect(result.actions.isEmpty)
        let conflict = try #require(result.conflicts.first)
        #expect(conflict.reason == .divergentItem)
        #expect(result.base.tombstone(for: syncID) != nil)
        #expect(result.base.item(for: syncID) == nil)
    }

    @Test func remoteMissingItemAndLocalEntryMissingConflict() throws {
        let remoteMissingID = UUID()
        let localMissingID = UUID()
        let localOnly = LanSyncTestFixtures.note(syncID: remoteMissingID, title: "Local only")
        let shared = LanSyncTestFixtures.note(syncID: localMissingID, title: "Shared")
        let base = LanSyncTestFixtures.makeBase(items: [
            (remoteMissingID, LanSyncTestFixtures.baseItem(for: localOnly, localEntryID: "entry-remote-missing")),
            (localMissingID, LanSyncTestFixtures.baseItem(for: shared, localEntryID: "entry-local-missing")),
        ])

        let result = engine.merge(
            remote: try LanSyncTestFixtures.snapshot(items: [shared]),
            localItems: [LanSyncTestFixtures.localItem(localOnly, entryID: "entry-remote-missing")],
            localTombstones: [],
            base: base,
            now: LanSyncTestFixtures.referenceDate
        )

        #expect(result.actions.isEmpty)
        #expect(result.conflicts.count == 2)
        let reasons = Dictionary(uniqueKeysWithValues: result.conflicts.map { ($0.syncID, $0.reason) })
        #expect(reasons[remoteMissingID] == .remoteMissingItem)
        #expect(reasons[localMissingID] == .localEntryMissing)
        let remoteMissingConflict = try #require(result.conflicts.first { $0.syncID == remoteMissingID })
        #expect(remoteMissingConflict.localEntryID == "entry-remote-missing")
        let localMissingConflict = try #require(result.conflicts.first { $0.syncID == localMissingID })
        #expect(localMissingConflict.localEntryID == "entry-local-missing")
    }

    @Test func baseIsIgnoredWhenPeerDeviceIDMismatches() throws {
        let syncID = UUID()
        let old = LanSyncTestFixtures.note(syncID: syncID, title: "Old", body: "old")
        let localEdit = LanSyncTestFixtures.note(syncID: syncID, title: "Old", body: "local edit")
        let remoteEdit = LanSyncTestFixtures.note(syncID: syncID, title: "Old", body: "remote edit")
        let staleBase = LanSyncTestFixtures.makeBase(
            peerDeviceID: "some-other-peer",
            items: [(syncID, LanSyncTestFixtures.baseItem(for: old))]
        )

        let result = engine.merge(
            remote: try LanSyncTestFixtures.snapshot(items: [remoteEdit], senderDeviceID: "peer-device-a"),
            localItems: [LanSyncTestFixtures.localItem(localEdit, entryID: "entry-1")],
            localTombstones: [],
            base: staleBase,
            now: LanSyncTestFixtures.referenceDate
        )

        // Without a usable base the two differing copies are divergent, not a
        // three-way "bothModified" conflict.
        #expect(result.actions.isEmpty)
        let conflict = try #require(result.conflicts.first)
        #expect(conflict.reason == .divergentItem)
        #expect(result.base.peerDeviceID == "peer-device-a")
        #expect(result.base.item(for: syncID) == nil)
    }

    @Test func localTombstoneWithRemoteModificationConflicts() throws {
        let syncID = UUID()
        let old = LanSyncTestFixtures.note(syncID: syncID, title: "Old", body: "old")
        let remoteEdit = LanSyncTestFixtures.note(syncID: syncID, title: "Old", body: "remote edit")
        let base = LanSyncTestFixtures.makeBase(items: [(syncID, LanSyncTestFixtures.baseItem(for: old))])
        let localTombstone = LanSyncTombstone(
            syncID: syncID,
            deletedAt: LanSyncTestFixtures.laterDate,
            deletedContentHash: old.contentHash
        )

        let result = engine.merge(
            remote: try LanSyncTestFixtures.snapshot(items: [remoteEdit]),
            localItems: [],
            localTombstones: [localTombstone],
            base: base,
            now: LanSyncTestFixtures.referenceDate
        )

        #expect(result.actions.isEmpty)
        let conflict = try #require(result.conflicts.first)
        #expect(conflict.reason == .localDeletedRemoteModified)
        #expect(conflict.remoteContentHash == remoteEdit.contentHash)
        #expect(result.base.item(for: syncID)?.contentHash == old.contentHash)
    }

    @Test func summaryCountsAndBaseAreUpdatedCorrectly() throws {
        let createID = UUID()
        let updateID = UUID()
        let deleteID = UUID()
        let conflictID = UUID()
        let missingID = UUID()

        let newItem = LanSyncTestFixtures.note(syncID: createID, title: "New")
        let oldUpdate = LanSyncTestFixtures.note(syncID: updateID, title: "Update", body: "old")
        let newUpdate = LanSyncTestFixtures.note(syncID: updateID, title: "Update", body: "new")
        let deleteItem = LanSyncTestFixtures.note(syncID: deleteID, title: "Delete")
        let oldConflict = LanSyncTestFixtures.note(syncID: conflictID, title: "Conflict", body: "old")
        let localConflict = LanSyncTestFixtures.note(syncID: conflictID, title: "Conflict", body: "local")
        let remoteConflict = LanSyncTestFixtures.note(syncID: conflictID, title: "Conflict", body: "remote")
        let missingItem = LanSyncTestFixtures.note(syncID: missingID, title: "Missing")

        let base = LanSyncTestFixtures.makeBase(items: [
            (updateID, LanSyncTestFixtures.baseItem(for: oldUpdate)),
            (deleteID, LanSyncTestFixtures.baseItem(for: deleteItem)),
            (conflictID, LanSyncTestFixtures.baseItem(for: oldConflict)),
            (missingID, LanSyncTestFixtures.baseItem(for: missingItem)),
        ])
        let remote = try LanSyncTestFixtures.snapshot(
            items: [newItem, newUpdate, remoteConflict],
            tombstones: [
                LanSyncTombstone(
                    syncID: deleteID,
                    deletedAt: LanSyncTestFixtures.laterDate,
                    deletedContentHash: deleteItem.contentHash
                ),
            ]
        )
        let localItems = [
            LanSyncTestFixtures.localItem(oldUpdate, entryID: "entry-update"),
            LanSyncTestFixtures.localItem(deleteItem, entryID: "entry-delete"),
            LanSyncTestFixtures.localItem(localConflict, entryID: "entry-conflict"),
            LanSyncTestFixtures.localItem(missingItem, entryID: "entry-missing"),
        ]

        let result = engine.merge(
            remote: remote,
            localItems: localItems,
            localTombstones: [],
            base: base,
            now: LanSyncTestFixtures.referenceDate
        )

        #expect(result.summary == LanSyncMergeSummary(created: 1, updated: 1, deleted: 1, conflicts: 2))
        #expect(result.summary.totalApplied == 3)
        #expect(result.actions.count == 3)
        #expect(result.conflicts.count == 2)
        #expect(result.base.peerDeviceID == "peer-device-a")
        #expect(result.base.lastSyncedAt == LanSyncTestFixtures.referenceDate)
        #expect(result.base.item(for: createID)?.contentHash == newItem.contentHash)
        #expect(result.base.item(for: updateID)?.contentHash == newUpdate.contentHash)
        #expect(result.base.tombstone(for: deleteID)?.lastContentHash == deleteItem.contentHash)
        #expect(result.base.item(for: missingID)?.contentHash == missingItem.contentHash)
    }

    @Test func mergeBaseRecordLocalEntryIDAndActionOrderingHelpers() {
        let item = LanSyncTestFixtures.note()
        var base = LanSyncMergeBase(peerDeviceID: "peer-device-a")
        #expect(!base.isSynchronized(item, localEntryID: nil))

        base.setItem(LanSyncTestFixtures.baseItem(for: item, localEntryID: nil), for: item.syncID)
        #expect(base.isSynchronized(item, localEntryID: nil))
        #expect(base.item(for: item.syncID)?.localEntryID == nil)

        base.recordLocalEntryID("created-entry", for: item.syncID)
        #expect(base.item(for: item.syncID)?.localEntryID == "created-entry")
        #expect(base.isSynchronized(item, localEntryID: "created-entry"))
        #expect(!base.isSynchronized(LanSyncTestFixtures.note(syncID: item.syncID, title: "Different"), localEntryID: "created-entry"))

        #expect(LanSyncMergeAction.create(item: item).ordersBeforeDeletes == 0)
        #expect(LanSyncMergeAction.update(item: item, localEntryID: "entry").ordersBeforeDeletes == 0)
        #expect(LanSyncMergeAction.delete(syncID: item.syncID, localEntryID: "entry").ordersBeforeDeletes == 1)
    }
}

// MARK: - State and ledger

@Suite("LanSync state and ledger", .serialized)
struct LanSyncStateTests {
    private func makePopulatedState() throws -> LanSyncSyncState {
        let syncID = UUID()
        var state = LanSyncSyncState(localDeviceID: "device-a", localVaultID: "vault-1")
        state.updatedAt = LanSyncTestFixtures.referenceDate
        state.upsertPeer(
            LanSyncPeerRecord(
                deviceID: "peer-1",
                displayName: "Peer One",
                signingPublicKey: Data(repeating: 0x21, count: 32),
                firstPairedAt: LanSyncTestFixtures.referenceDate,
                lastSyncedAt: nil,
                lastSessionFingerprint: "abc123"
            )
        )
        var base = LanSyncMergeBase(peerDeviceID: "peer-1", lastSyncedAt: LanSyncTestFixtures.referenceDate)
        base.setItem(
            LanSyncMergeBaseItem(contentHash: Data([1, 2, 3]), localEntryID: "entry-1", kind: .note),
            for: syncID
        )
        state.setBase(base, forPeer: "peer-1")
        state.setMapping(
            LanSyncEntryMapping(
                localEntryID: "entry-1",
                syncID: syncID,
                kind: .note,
                lastKnownContentHash: Data([1, 2, 3])
            )
        )
        state.ledger.remember(
            LanSyncTransferRecord(
                transferID: "transfer-1",
                snapshotDigest: Data([9, 9]),
                receiverDeviceID: "device-a",
                summary: LanSyncMergeSummary(created: 1, updated: 2, deleted: 3, conflicts: 4),
                appliedAt: LanSyncTestFixtures.referenceDate
            )
        )
        return state
    }

    @Test func syncStateCodecRoundTrips() throws {
        let state = try makePopulatedState()
        let encoded = try LanSyncSyncStateCodec.encode(state)
        let decoded = try LanSyncSyncStateCodec.decode(encoded)
        #expect(decoded == state)
    }

    @Test func syncStateEncodingIsPrettyPrintedWithSortedKeys() throws {
        let encoded = try LanSyncSyncStateCodec.encode(try makePopulatedState())
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains("\n"))
        let bases = try #require(text.range(of: "\"bases\""))
        let formatVersion = try #require(text.range(of: "\"formatVersion\""))
        let ledger = try #require(text.range(of: "\"ledger\""))
        let localDevice = try #require(text.range(of: "\"localDeviceID\""))
        let mappings = try #require(text.range(of: "\"mappings\""))
        let peers = try #require(text.range(of: "\"peers\""))
        #expect(bases.lowerBound < formatVersion.lowerBound)
        #expect(formatVersion.lowerBound < ledger.lowerBound)
        #expect(ledger.lowerBound < localDevice.lowerBound)
        #expect(localDevice.lowerBound < mappings.lowerBound)
        #expect(mappings.lowerBound < peers.lowerBound)
    }

    @Test func unsupportedFormatVersionAndCorruptedStateAreRejected() throws {
        var state = try makePopulatedState()
        state.formatVersion = LanSyncProtocolSpec.syncStateFormatVersion + 1
        let encoded = try JSONEncoder().encode(state)
        expectThrows(LanSyncStateError.unsupportedFormatVersion(LanSyncProtocolSpec.syncStateFormatVersion + 1)) {
            _ = try LanSyncSyncStateCodec.decode(encoded)
        }
        expectThrows(LanSyncStateError.corruptedState) {
            _ = try LanSyncSyncStateCodec.decode(Data("{}".utf8))
        }
    }

    @Test func mappingAndBaseHelpersWork() throws {
        var state = LanSyncSyncState(localDeviceID: "device-a", localVaultID: "vault-1")
        let syncID = UUID()
        let mapping = LanSyncEntryMapping(localEntryID: "entry-1", syncID: syncID, kind: .login)
        state.setMapping(mapping)

        #expect(state.mapping(forLocalEntryID: "entry-1") == mapping)
        #expect(state.mapping(forSyncID: syncID) == mapping)
        #expect(state.knownSyncIDs == [syncID])
        state.removeMapping(forLocalEntryID: "entry-1")
        #expect(state.mapping(forLocalEntryID: "entry-1") == nil)
        #expect(state.mapping(forSyncID: syncID) == nil)

        let base = LanSyncMergeBase(peerDeviceID: "peer-1")
        #expect(state.base(forPeer: "peer-1") == nil)
        state.setBase(base, forPeer: "peer-1")
        #expect(state.base(forPeer: "peer-1") == base)
    }

    @Test func peerUpsertPreservesFirstPairedDateAndBuildsExpectedPeer() {
        var state = LanSyncSyncState(localDeviceID: "device-a", localVaultID: "vault-1")
        let original = LanSyncPeerRecord(
            deviceID: "peer-1",
            displayName: "Original",
            signingPublicKey: Data(repeating: 0x31, count: 32),
            firstPairedAt: LanSyncTestFixtures.referenceDate,
            lastSyncedAt: nil
        )
        state.upsertPeer(original)
        state.upsertPeer(
            LanSyncPeerRecord(
                deviceID: "peer-1",
                displayName: "Renamed",
                signingPublicKey: Data(repeating: 0x32, count: 32),
                firstPairedAt: LanSyncTestFixtures.laterDate,
                lastSyncedAt: LanSyncTestFixtures.laterDate
            )
        )

        #expect(state.peers.count == 1)
        #expect(state.peer("peer-1")?.displayName == "Renamed")
        #expect(state.peer("peer-1")?.firstPairedAt == LanSyncTestFixtures.referenceDate)
        #expect(state.peer("peer-1")?.lastSyncedAt == LanSyncTestFixtures.laterDate)

        let expectedPeer = state.expectedPeer(for: "peer-1")
        #expect(expectedPeer?.deviceID == "peer-1")
        #expect(expectedPeer?.displayName == "Renamed")
        #expect(expectedPeer?.signingPublicKey == Data(repeating: 0x32, count: 32))
        #expect(state.expectedPeer(for: "unknown") == nil)
    }

    @Test func transferLedgerRemembersAtMost32RecordsAndEvictsOldest() {
        var ledger = LanSyncTransferLedger()
        for index in 0..<40 {
            ledger.remember(
                LanSyncTransferRecord(
                    transferID: "transfer-\(index)",
                    snapshotDigest: Data([UInt8(index)]),
                    receiverDeviceID: "device-a",
                    summary: LanSyncMergeSummary(),
                    appliedAt: LanSyncTestFixtures.referenceDate
                )
            )
        }

        #expect(ledger.records.count == LanSyncTransferLedger.maxRecords)
        #expect(ledger.records.count == 32)
        #expect(ledger.records.first?.transferID == "transfer-8")
        #expect(ledger.records.last?.transferID == "transfer-39")

        // Remembering an existing transfer ID replaces the old record instead of
        // growing the ledger.
        ledger.remember(
            LanSyncTransferRecord(
                transferID: "transfer-39",
                snapshotDigest: Data([0xFF]),
                receiverDeviceID: "device-a",
                summary: LanSyncMergeSummary(created: 5),
                appliedAt: LanSyncTestFixtures.laterDate
            )
        )
        #expect(ledger.records.count == 32)
        #expect(ledger.record(forTransferID: "transfer-39")?.snapshotDigest == Data([0xFF]))
        #expect(ledger.record(forTransferID: "transfer-39")?.created == 5)
    }

    @Test func previousApplicationRequiresMatchingDigest() {
        var ledger = LanSyncTransferLedger()
        let record = LanSyncTransferRecord(
            transferID: "transfer-1",
            snapshotDigest: Data([1, 2, 3]),
            receiverDeviceID: "device-a",
            summary: LanSyncMergeSummary(created: 2, conflicts: 1),
            appliedAt: LanSyncTestFixtures.referenceDate
        )
        ledger.remember(record)

        #expect(ledger.previousApplication(transferID: "transfer-1", digest: Data([1, 2, 3])) == record)
        #expect(ledger.previousApplication(transferID: "transfer-1", digest: Data([3, 2, 1])) == nil)
        #expect(ledger.previousApplication(transferID: "missing", digest: Data([1, 2, 3])) == nil)
        #expect(ledger.hasConflictingTransfer(transferID: "transfer-1", digest: Data([3, 2, 1])))
        #expect(!ledger.hasConflictingTransfer(transferID: "transfer-1", digest: Data([1, 2, 3])))
        #expect(!ledger.hasConflictingTransfer(transferID: "missing", digest: Data([1])))
    }

    @Test func receiptCopiesLedgerFieldsAndAlreadyAppliedFlag() {
        let summary = LanSyncMergeSummary(created: 2, updated: 1, deleted: 3, conflicts: 4)
        let record = LanSyncTransferRecord(
            transferID: "transfer-9",
            snapshotDigest: Data([7, 7, 7]),
            receiverDeviceID: "device-b",
            summary: summary,
            appliedAt: LanSyncTestFixtures.referenceDate
        )

        let appliedReceipt = record.receipt(alreadyApplied: true)
        #expect(appliedReceipt.alreadyApplied)
        #expect(appliedReceipt.transferID == "transfer-9")
        #expect(appliedReceipt.snapshotDigest == Data([7, 7, 7]))
        #expect(appliedReceipt.receiverDeviceID == "device-b")
        #expect(appliedReceipt.summary == summary)
        #expect(appliedReceipt.completedAt == LanSyncTestFixtures.referenceDate)

        let freshReceipt = record.receipt(alreadyApplied: false)
        #expect(!freshReceipt.alreadyApplied)

        let transferID = LanSyncTransferID.make()
        #expect(LanSyncTransferID.isCanonical(transferID))
        #expect(!LanSyncTransferID.isCanonical("not-a-uuid"))
    }
}
