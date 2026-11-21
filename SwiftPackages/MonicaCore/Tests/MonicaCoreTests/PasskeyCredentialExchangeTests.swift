import CryptoKit
import Foundation
import Security
import Testing
@testable import MonicaCore

/// A key store that fails with a configurable keychain status, used to model "no permission" and
/// "revoked storage" paths without touching the real keychain.
private final class FailingPasskeyPrivateKeyStore: PasskeyPrivateKeyStore, @unchecked Sendable {
    enum Failure: String, Sendable {
        case missing
        case permissionDenied
        case writePermissionDenied
        case unexpected
        case referenceMismatch
    }

    private let failure: Failure
    private let lock = NSLock()
    private var privateKeys: [Data: Data] = [:]
    private(set) var deleteCount = 0

    init(failure: Failure) {
        self.failure = failure
    }

    func savePrivateKey(_ privateKey: Data, credentialID: Data) throws -> String {
        switch failure {
        case .permissionDenied, .writePermissionDenied:
            throw PasskeyCredentialError.keychainUnexpectedStatus(errSecAuthFailed)
        case .unexpected:
            throw PasskeyCredentialError.keychainUnexpectedStatus(errSecDuplicateItem)
        case .referenceMismatch:
            lock.lock()
            privateKeys[credentialID] = privateKey
            lock.unlock()
            return "monica-passkey://unexpected-reference"
        case .missing:
            lock.lock()
            privateKeys[credentialID] = privateKey
            lock.unlock()
            return PasskeyCredentialReference.reference(for: credentialID)
        }
    }

    func loadPrivateKey(credentialID: Data) throws -> Data? {
        switch failure {
        case .permissionDenied:
            throw PasskeyCredentialError.keychainUnexpectedStatus(errSecAuthFailed)
        case .unexpected:
            throw PasskeyCredentialError.keychainUnexpectedStatus(errSecNotAvailable)
        default:
            lock.lock()
            defer { lock.unlock() }
            return privateKeys[credentialID]
        }
    }

    func deletePrivateKey(credentialID: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        deleteCount += 1
        privateKeys.removeValue(forKey: credentialID)
    }
}

private func makePrivateKey() -> (raw: Data, der: Data) {
    let key = P256.Signing.PrivateKey()
    return (key.rawRepresentation, key.derRepresentation)
}

private func makeCredential(
    credentialID: Data = Data(repeating: 0x11, count: 32),
    relyingPartyID: String = "github.com",
    userName: String = "joyin@example.com",
    userDisplayName: String = "Joyin",
    userHandle: Data = Data("github-user-handle".utf8),
    privateKey: Data
) -> PasskeyExchangeCredential {
    PasskeyExchangeCredential(
        credentialID: credentialID,
        relyingPartyID: relyingPartyID,
        userName: userName,
        userDisplayName: userDisplayName,
        userHandle: userHandle,
        privateKey: privateKey
    )
}

@Test func passkeyExchangePrepareImportDerivesPublicKeyWithoutTouchingKeychain() throws {
    let store = MemoryPasskeyPrivateKeyStore()
    let service = PasskeyExchangeService(privateKeyStore: store)
    let key = makePrivateKey()
    let credential = makeCredential(relyingPartyID: "  GitHub.com.  ", privateKey: key.der)
    let credentialID = credential.credentialID

    let prepared = try service.prepareImport(credential, title: " GitHub ")

    #expect(prepared.relyingPartyID == "github.com")
    #expect(prepared.username == "joyin@example.com")
    #expect(prepared.credentialID == credentialID)
    #expect(prepared.privateKeyReference == PasskeyCredentialReference.reference(for: credentialID))
    #expect(prepared.metadata.title == "GitHub")
    #expect(prepared.metadata.relyingPartyID == "github.com")
    #expect(prepared.metadata.username == "joyin@example.com")
    #expect(prepared.metadata.credentialID == credentialID.base64EncodedString())
    #expect(prepared.metadata.userHandle == credential.userHandle.base64EncodedString())
    let coseKey = try #require(Data(base64Encoded: prepared.metadata.publicKeyCOSE))
    #expect(coseKey.first == 0xA5, "COSE_Key 必须以 CBOR map(5) 开头")
    #expect(coseKey.count > 70)
    // 预览阶段不得写入安全存储。
    #expect(try store.loadPrivateKey(credentialID: credentialID) == nil)
}

@Test func passkeyExchangeRoundTripPreservesPrivateKey() throws {
    let store = MemoryPasskeyPrivateKeyStore()
    let service = PasskeyExchangeService(privateKeyStore: store)
    let key = makePrivateKey()
    let credential = makeCredential(privateKey: key.der)

    let prepared = try service.prepareImport(credential, title: "GitHub")
    #expect(try service.commitImport(prepared) == prepared.privateKeyReference)
    #expect(try store.loadPrivateKey(credentialID: credential.credentialID) == key.raw)

    let exported = try service.exportCredential(
        credentialID: credential.credentialID,
        relyingPartyID: credential.relyingPartyID,
        userName: credential.userName,
        userDisplayName: credential.userDisplayName,
        userHandle: credential.userHandle
    )

    #expect(exported.credentialID == credential.credentialID)
    #expect(exported.relyingPartyID == "github.com")
    #expect(exported.userName == credential.userName)
    #expect(exported.userDisplayName == "Joyin")
    #expect(exported.userHandle == credential.userHandle)
    // CXF 要求 PKCS#8 DER 而不是裸私钥。
    #expect(exported.privateKey.first == 0x30)
    #expect(exported.privateKey != key.raw)
    #expect(try PasskeyExchangeService.rawPrivateKey(from: exported.privateKey) == key.raw)
}

@Test func passkeyExchangeImportAcceptsRawAndPKCS8Envelopes() throws {
    let key = makePrivateKey()

    #expect(try PasskeyExchangeService.rawPrivateKey(from: key.raw) == key.raw)
    #expect(try PasskeyExchangeService.rawPrivateKey(from: key.der) == key.raw)
    #expect(throws: PasskeyExchangeError.invalidPrivateKey) {
        _ = try PasskeyExchangeService.rawPrivateKey(from: Data())
    }
    #expect(throws: PasskeyExchangeError.invalidPrivateKey) {
        _ = try PasskeyExchangeService.rawPrivateKey(from: Data(repeating: 0x7F, count: 40))
    }
}

@Test func passkeyExchangeRejectsInvalidEntriesIndividually() throws {
    let service = PasskeyExchangeService(privateKeyStore: MemoryPasskeyPrivateKeyStore())
    let key = makePrivateKey()

    #expect(throws: PasskeyExchangeError.invalidCredentialID) {
        _ = try service.prepareImport(
            makeCredential(credentialID: Data(), privateKey: key.der),
            title: "空 ID"
        )
    }
    #expect(throws: PasskeyExchangeError.invalidRelyingPartyID) {
        _ = try service.prepareImport(
            makeCredential(relyingPartyID: "https://github.com/login", privateKey: key.der),
            title: "坏 RP ID"
        )
    }
    #expect(throws: PasskeyExchangeError.invalidUsername) {
        _ = try service.prepareImport(
            makeCredential(userName: "   ", privateKey: key.der),
            title: "空用户名"
        )
    }
    #expect(throws: PasskeyExchangeError.invalidUserHandle) {
        _ = try service.prepareImport(
            makeCredential(userHandle: Data(), privateKey: key.der),
            title: "空 handle"
        )
    }
    #expect(throws: PasskeyExchangeError.invalidPrivateKey) {
        _ = try service.prepareImport(
            makeCredential(privateKey: Data(repeating: 0xAB, count: 12)),
            title: "坏私钥"
        )
    }
}

@Test func passkeyExchangeReportsMissingRevokedAndDeniedKeys() throws {
    let key = makePrivateKey()
    let credential = makeCredential(privateKey: key.der)

    let missingStore = MemoryPasskeyPrivateKeyStore()
    let missingService = PasskeyExchangeService(privateKeyStore: missingStore)
    #expect(throws: PasskeyExchangeError.privateKeyNotFound) {
        _ = try missingService.exportCredential(
            credentialID: credential.credentialID,
            relyingPartyID: credential.relyingPartyID,
            userName: credential.userName,
            userHandle: credential.userHandle
        )
    }

    // 私钥被撤销/删除后不能再导出。
    let revokedStore = MemoryPasskeyPrivateKeyStore()
    let revokedService = PasskeyExchangeService(privateKeyStore: revokedStore)
    let prepared = try revokedService.prepareImport(credential, title: "GitHub")
    try revokedService.commitImport(prepared)
    try revokedService.deletePrivateKey(credentialID: credential.credentialID)
    #expect(throws: PasskeyExchangeError.privateKeyNotFound) {
        _ = try revokedService.exportCredential(
            credentialID: credential.credentialID,
            relyingPartyID: credential.relyingPartyID,
            userName: credential.userName,
            userHandle: credential.userHandle
        )
    }

    // 设备所有者拒绝授权时，keychain 返回 errSecAuthFailed。
    let deniedService = PasskeyExchangeService(privateKeyStore: FailingPasskeyPrivateKeyStore(failure: .permissionDenied))
    #expect(throws: PasskeyExchangeError.privateKeyAccessDenied) {
        _ = try deniedService.exportCredential(
            credentialID: credential.credentialID,
            relyingPartyID: credential.relyingPartyID,
            userName: credential.userName,
            userHandle: credential.userHandle
        )
    }
    let deniedWriteService = PasskeyExchangeService(
        privateKeyStore: FailingPasskeyPrivateKeyStore(failure: .writePermissionDenied)
    )
    #expect(throws: PasskeyExchangeError.privateKeyAccessDenied) {
        _ = try deniedWriteService.commitImport(prepared)
    }
}

@Test func passkeyExchangeMapsUnexpectedKeychainStatusAndReferenceMismatch() throws {
    let service = PasskeyExchangeService(privateKeyStore: FailingPasskeyPrivateKeyStore(failure: .unexpected))
    let credential = makeCredential(privateKey: makePrivateKey().der)

    let prepared = try service.prepareImport(credential, title: "GitHub")
    #expect(throws: PasskeyExchangeError.keychainUnexpectedStatus(errSecDuplicateItem)) {
        _ = try service.commitImport(prepared)
    }

    let mismatchStore = FailingPasskeyPrivateKeyStore(failure: .referenceMismatch)
    let mismatchService = PasskeyExchangeService(privateKeyStore: mismatchStore)
    let mismatchPrepared = try mismatchService.prepareImport(credential, title: "GitHub")
    #expect(throws: PasskeyExchangeError.privateKeyReferenceMismatch) {
        _ = try mismatchService.commitImport(mismatchPrepared)
    }
    // 引用不匹配时必须清理已经写入的私钥，避免孤儿密钥。
    #expect(mismatchStore.deleteCount == 1)
}

@Test func passkeyExchangeRollbackIsIdempotent() throws {
    let store = MemoryPasskeyPrivateKeyStore()
    let service = PasskeyExchangeService(privateKeyStore: store)
    let credential = makeCredential(privateKey: makePrivateKey().der)
    let prepared = try service.prepareImport(credential, title: "GitHub")

    try service.commitImport(prepared)
    #expect(try store.loadPrivateKey(credentialID: credential.credentialID) != nil)
    try service.rollbackImport(prepared)
    #expect(try store.loadPrivateKey(credentialID: credential.credentialID) == nil)
    // 再次回滚不应抛错。
    try service.rollbackImport(prepared)
    try service.deletePrivateKey(credentialID: credential.credentialID)
}

@Test func passkeyExchangeNeverWritesPrivateKeyIntoMetadata() throws {
    let service = PasskeyExchangeService(privateKeyStore: MemoryPasskeyPrivateKeyStore())
    let key = makePrivateKey()
    let prepared = try service.prepareImport(makeCredential(privateKey: key.der), title: "GitHub", notes: "备注")

    let metadataValues = [
        prepared.metadata.title,
        prepared.metadata.relyingPartyID,
        prepared.metadata.username,
        prepared.metadata.userHandle,
        prepared.metadata.credentialID,
        prepared.metadata.publicKeyCOSE,
        prepared.metadata.privateKeyReference,
        prepared.metadata.notes
    ]
    let rawBase64 = key.raw.base64EncodedString()
    let derBase64 = key.der.base64EncodedString()
    for value in metadataValues {
        #expect(!value.contains(rawBase64))
        #expect(!value.contains(derBase64))
    }
    #expect(prepared.metadata.notes == "备注")
}
