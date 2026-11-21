@testable import Monica
import AuthenticationServices
import CryptoKit
import MonicaCore
import MonicaSecurity
import MonicaStorage
import MonicaSync
import MonicaWidgetShared
import SwiftUI
import UIKit
import XCTest

final class RecordingAppAutoFillIndexKeyMaterialStore: AppAutoFillIndexKeyMaterialStore {
    private var keys: [String: AutoFillIndexKeyMaterial] = [:]
    private(set) var savedKeyMaterials: [AutoFillIndexKeyMaterial] = []

    func loadKeyMaterial(vaultID: String) throws -> AutoFillIndexKeyMaterial? {
        keys[vaultID]
    }

    func saveKeyMaterial(_ keyMaterial: AutoFillIndexKeyMaterial) throws {
        keys[keyMaterial.vaultID] = keyMaterial
        savedKeyMaterials.append(keyMaterial)
    }
}

final class RecordingAutoFillEncryptedIndexStore: AutoFillEncryptedIndexStore, @unchecked Sendable {
    private(set) var savedIndexes: [AutoFillEncryptedIndex] = []

    func save(_ index: AutoFillEncryptedIndex) throws {
        savedIndexes.append(index)
    }

    func load() throws -> AutoFillEncryptedIndex? {
        savedIndexes.last
    }

    func delete() throws {
        savedIndexes.removeAll()
    }
}

final class RecordingAutoFillCredentialSecretStore: AutoFillCredentialSecretStore, @unchecked Sendable {
    private(set) var savedSnapshots: [AutoFillCredentialSecretSnapshot] = []

    func save(_ snapshot: AutoFillCredentialSecretSnapshot) throws {
        savedSnapshots.append(snapshot)
    }

    func load() throws -> AutoFillCredentialSecretSnapshot? {
        savedSnapshots.last
    }

    func delete() throws {
        savedSnapshots.removeAll()
    }
}

final class RecordingAutoFillCredentialIdentityStore: AppAutoFillCredentialIdentityStore, @unchecked Sendable {
    private(set) var savedIdentities: [[AppAutoFillCredentialIdentity]] = []
    private(set) var savedPasskeyIdentities: [[AppAutoFillPasskeyCredentialIdentity]] = []
    private(set) var removeAllCallCount = 0
    var identityStoreStatus: AppAutoFillIdentityStoreStatus?

    func replaceCredentialIdentities(
        _ identities: [AppAutoFillCredentialIdentity],
        passkeyIdentities: [AppAutoFillPasskeyCredentialIdentity]
    ) {
        savedIdentities.append(identities)
        savedPasskeyIdentities.append(passkeyIdentities)
    }

    func loadIdentityStoreStatus() async -> AppAutoFillIdentityStoreStatus? {
        identityStoreStatus
    }

    func removeAllPublishedIdentities() async {
        removeAllCallCount += 1
    }
}

final class RecordingKeePassKdbx4WritebackCoordinator: KeePassKdbx4WritebackCoordinator, @unchecked Sendable {
    private(set) var requests: [KeePassKdbx4WritebackRequest] = []
    var result = KeePassKdbx4WritebackResult(
        database: Data("recorded-kdbx".utf8),
        headerBytes: Data(),
        payloadSection: Data(),
        xmlPayloadByteCount: 0,
        groupCount: 0,
        entryCount: 0,
        attachmentCount: 0
    )
    var error: Error?

    func writeDatabase(_ request: KeePassKdbx4WritebackRequest) throws -> KeePassKdbx4WritebackResult {
        requests.append(request)
        if let error {
            throw error
        }
        return result
    }
}

final class RecordingKeePassKdbx3WritebackCoordinator: KeePassKdbx3WritebackCoordinator, @unchecked Sendable {
    private(set) var requests: [KeePassKdbx3WritebackRequest] = []
    var result = KeePassKdbx3WritebackResult(
        database: Data("recorded-kdbx3".utf8),
        headerBytes: Data(),
        encryptedPayload: Data(),
        xmlPayloadByteCount: 0,
        groupCount: 0,
        entryCount: 0,
        attachmentCount: 0
    )
    var error: Error?

    func writeDatabase(_ request: KeePassKdbx3WritebackRequest) throws -> KeePassKdbx3WritebackResult {
        requests.append(request)
        if let error {
            throw error
        }
        return result
    }
}

final class RecordingAppVaultKeychainService: AppVaultKeychainService, @unchecked Sendable {
    private(set) var savedWrappedKeys: [WrappedVaultKey] = []
    private(set) var loadRequests: [(vaultID: String, reason: String)] = []
    var loadedWrappedKey: WrappedVaultKey?
    var saveError: Error?
    var loadError: Error?

    func saveWrappedKey(_ key: WrappedVaultKey) async throws {
        if let saveError {
            throw saveError
        }
        savedWrappedKeys.append(key)
        loadedWrappedKey = key
    }

    func loadWrappedKeyAfterAuthentication(
        vaultID: String,
        reason: String
    ) async throws -> WrappedVaultKey {
        loadRequests.append((vaultID, reason))
        if let loadError {
            throw loadError
        }
        guard let loadedWrappedKey else {
            throw MonicaSecurityError.wrappedKeyNotFound
        }
        return loadedWrappedKey
    }

}

final class RecordingBiometricUnlockAuthorizer: BiometricUnlockAuthorizer, @unchecked Sendable {
    private(set) var authenticationReasons: [String] = []
    let kind: BiometricUnlockKind

    init(kind: BiometricUnlockKind) {
        self.kind = kind
    }

    func authenticate(reason: String) async throws {
        authenticationReasons.append(reason)
    }
}

final class RecordingAppWebDAVBackupService: AppWebDAVBackupService, @unchecked Sendable {
    private(set) var uploads: [(endpoint: WebDAVEndpoint, package: WebDAVBackupPackage)] = []
    private(set) var downloads: [(endpoint: WebDAVEndpoint, fileName: String)] = []
    private(set) var listRequests: [WebDAVEndpoint] = []
    private(set) var deleteRequests: [(endpoint: WebDAVEndpoint, fileName: String)] = []
    private(set) var permanentRequests: [(endpoint: WebDAVEndpoint, fileName: String, isPermanent: Bool)] = []
    private(set) var cleanupRequests: [(endpoint: WebDAVEndpoint, backups: [WebDAVBackupItem], cutoff: Date)] = []
    var uploadReceipt = WebDAVBackupReceipt(
        remoteURL: URL(string: "https://dav.example.com/backups/mobile.mdbx")!,
        byteCount: 11,
        sha256: "receipt-sha"
    )
    var uploadError: Error?
    var downloadedBackup = WebDAVDownloadedBackup(
        fileName: "mobile.mdbx",
        remoteURL: URL(string: "https://dav.example.com/backups/mobile.mdbx")!,
        data: Data("remote-vault".utf8),
        sha256: "remote-sha"
    )
    var downloadError: Error?
    var backups: [WebDAVBackupItem] = [
        WebDAVBackupItem(fileName: "mobile.mdbx", byteCount: 11)
    ]
    var listError: Error?
    var deleteError: Error?
    var permanentError: Error?
    var cleanupError: Error?

    func upload(endpoint: WebDAVEndpoint, package: WebDAVBackupPackage) async throws -> WebDAVBackupReceipt {
        uploads.append((endpoint, package))
        if let uploadError {
            throw uploadError
        }
        return uploadReceipt
    }

    func download(endpoint: WebDAVEndpoint, fileName: String) async throws -> WebDAVDownloadedBackup {
        downloads.append((endpoint, fileName))
        if let downloadError {
            throw downloadError
        }
        return downloadedBackup
    }

    func listBackups(endpoint: WebDAVEndpoint) async throws -> [WebDAVBackupItem] {
        listRequests.append(endpoint)
        if let listError {
            throw listError
        }
        return backups
    }

    func deleteBackup(endpoint: WebDAVEndpoint, fileName: String) async throws {
        deleteRequests.append((endpoint, fileName))
        if let deleteError {
            throw deleteError
        }
        backups.removeAll { $0.fileName == fileName }
    }

    func setBackupPermanent(
        endpoint: WebDAVEndpoint,
        fileName: String,
        isPermanent: Bool
    ) async throws -> WebDAVBackupItem {
        permanentRequests.append((endpoint, fileName, isPermanent))
        if let permanentError {
            throw permanentError
        }
        let baseName = fileName.replacingOccurrences(of: ".mdbx", with: "")
        let nextName = isPermanent
            ? "\(baseName)_permanent.mdbx"
            : baseName.replacingOccurrences(of: "_permanent", with: "") + ".mdbx"
        let item = WebDAVBackupItem(fileName: nextName, byteCount: backups.first { $0.fileName == fileName }?.byteCount ?? 0)
        backups.removeAll { $0.fileName == fileName }
        backups.append(item)
        return item
    }

    func cleanupBackups(
        endpoint: WebDAVEndpoint,
        backups: [WebDAVBackupItem],
        olderThan cutoff: Date
    ) async throws -> [WebDAVBackupItem] {
        cleanupRequests.append((endpoint, backups, cutoff))
        if let cleanupError {
            throw cleanupError
        }
        let deleted = backups.filter { item in
            guard !item.isPermanent, let modifiedAt = item.modifiedAt else {
                return false
            }
            return modifiedAt < cutoff
        }
        self.backups.removeAll { item in deleted.contains(item) }
        return deleted
    }
}

final class RecordingCloudFileProvider: CloudFileProvider, @unchecked Sendable {
    let kind: CloudFileProviderKind
    var connection: CloudFileConnectionState
    var items: [CloudFileItem] = []
    var downloads: [String: CloudFileDownload] = [:]
    private(set) var listCallCount = 0
    private(set) var downloadRequests: [String] = []
    private(set) var uploads: [(fileName: String, data: Data)] = []
    private(set) var overwrites: [(itemID: String, fileName: String, data: Data, expectedRevision: String?)] = []
    var error: Error?

    init(kind: CloudFileProviderKind) {
        self.kind = kind
        self.connection = .connected(accountLabel: "\(kind.displayName) account")
    }

    func connectionState() async throws -> CloudFileConnectionState {
        if let error {
            throw error
        }
        return connection
    }

    func listFiles() async throws -> [CloudFileItem] {
        listCallCount += 1
        if let error {
            throw error
        }
        return items
    }

    func downloadFile(id: String) async throws -> CloudFileDownload {
        downloadRequests.append(id)
        if let error {
            throw error
        }
        guard let download = downloads[id] else {
            throw CloudFileProviderError.itemNotFound(provider: kind)
        }
        return download
    }

    func uploadFile(named fileName: String, data: Data) async throws -> CloudFileWriteReceipt {
        uploads.append((fileName, data))
        if let error {
            throw error
        }
        return CloudFileWriteReceipt(
            provider: kind,
            itemID: "\(kind.rawValue)-uploaded-secret-id",
            name: fileName,
            byteCount: data.count,
            sha256: "\(kind.rawValue)-upload-sha-secret"
        )
    }

    func overwriteFile(
        id: String,
        data: Data,
        fileName: String,
        expectedRevision: String?
    ) async throws -> CloudFileWriteReceipt {
        overwrites.append((id, fileName, data, expectedRevision))
        if let error {
            throw error
        }
        return CloudFileWriteReceipt(
            provider: kind,
            itemID: id,
            name: fileName,
            byteCount: data.count,
            sha256: "\(kind.rawValue)-overwrite-sha-secret",
            revision: "\(kind.rawValue)-overwrite-etag-secret"
        )
    }
}

final class RecordingBitwardenSyncProvider: BitwardenSyncProvider, @unchecked Sendable {
    var snapshot = BitwardenSyncSnapshot(
        accountLabel: "alice@example.com",
        revision: "initial-revision"
    )
    var pushResult = BitwardenSyncPushResult(acceptedMutationCount: 0)
    var downloadAttachmentResult = BitwardenAttachmentDownloadResult(encryptedContent: Data())
    var pullError: Error?
    var pushError: Error?
    var downloadAttachmentError: Error?
    private(set) var pullCallCount = 0
    private(set) var pushedMutations: [BitwardenSyncMutation] = []
    private(set) var downloadAttachmentRequests: [BitwardenAttachmentDownloadRequest] = []
    var textSendResult = BitwardenTextSendCreateResult(
        remoteID: "text-send-remote-id",
        link: BitwardenSendLink(accessID: "text-send-access-id", keyMaterial: Data(repeating: 7, count: 16))
    )
    var receivedSend = BitwardenReceivedSend(title: "Received", text: "received-body")
    var textSendError: Error?
    var fetchSendError: Error?
    private(set) var textSendRequests: [BitwardenTextSendCreateRequest] = []
    private(set) var fetchSendRequests: [BitwardenSendFetchRequest] = []

    func pullSnapshot() async throws -> BitwardenSyncSnapshot {
        pullCallCount += 1
        if let pullError {
            throw pullError
        }
        return snapshot
    }

    func pushMutations(_ mutations: [BitwardenSyncMutation]) async throws -> BitwardenSyncPushResult {
        pushedMutations.append(contentsOf: mutations)
        if let pushError {
            throw pushError
        }
        return pushResult
    }

    func downloadAttachment(_ request: BitwardenAttachmentDownloadRequest) async throws -> BitwardenAttachmentDownloadResult {
        downloadAttachmentRequests.append(request)
        if let downloadAttachmentError {
            throw downloadAttachmentError
        }
        return downloadAttachmentResult
    }

    func createTextSend(_ request: BitwardenTextSendCreateRequest) async throws -> BitwardenTextSendCreateResult {
        textSendRequests.append(request)
        if let textSendError {
            throw textSendError
        }
        return textSendResult
    }

    func fetchSend(_ request: BitwardenSendFetchRequest) async throws -> BitwardenReceivedSend {
        fetchSendRequests.append(request)
        if let fetchSendError {
            throw fetchSendError
        }
        return receivedSend
    }
}

final class RecordingAppBitwardenVaultSyncTransport: BitwardenVaultSyncTransport, @unchecked Sendable {
    private(set) var requests: [BitwardenVaultSyncRequest] = []
    private var responses: [BitwardenVaultSyncResponse] = []

    func enqueue(statusCode: Int, body: String, headers: [String: String] = [:]) {
        responses.append(
            BitwardenVaultSyncResponse(
                statusCode: statusCode,
                headers: headers,
                body: Data(body.utf8)
            )
        )
    }

    func send(_ request: BitwardenVaultSyncRequest) async throws -> BitwardenVaultSyncResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        return responses.removeFirst()
    }
}

func decodedJSONDictionary(_ data: Data?) throws -> [String: Any] {
    let data = try XCTUnwrap(data)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

final class RecordingAppBitwardenPasswordAuthenticationService: AppBitwardenPasswordAuthenticationService, @unchecked Sendable {
    struct Request: Equatable {
        let email: String
        let masterPassword: String
        let serverURL: URL
    }

    struct TwoFactorRequest: Equatable {
        let providerID: Int
        let code: String
        let rememberDevice: Bool
    }

    var session = BitwardenAuthenticationSession(
        accountLabel: "alice@example.com",
        serverURL: URL(string: "https://vault.bitwarden.com")!,
        identityURL: URL(string: "https://identity.bitwarden.com")!,
        apiURL: URL(string: "https://api.bitwarden.com")!,
        accessToken: "access-token-secret",
        refreshToken: "refresh-token-secret",
        expiresAt: Date(timeIntervalSince1970: 1_804_000_000)
    )
    var beginResult: BitwardenPasswordAuthenticationResult?
    var error: Error?
    private(set) var requests: [Request] = []
    private(set) var twoFactorRequests: [TwoFactorRequest] = []
    private(set) var emailCodeRequestCount = 0

    func beginSignIn(
        email: String,
        masterPassword: String,
        serverURL: URL
    ) async throws -> BitwardenPasswordAuthenticationResult {
        requests.append(Request(email: email, masterPassword: masterPassword, serverURL: serverURL))
        if let error {
            throw error
        }
        return beginResult ?? .authenticated(session)
    }

    func completeTwoFactorSignIn(
        _ challenge: BitwardenTwoFactorLoginChallenge,
        code: String,
        providerID: Int,
        rememberDevice: Bool
    ) async throws -> BitwardenAuthenticationSession {
        twoFactorRequests.append(
            TwoFactorRequest(
                providerID: providerID,
                code: code,
                rememberDevice: rememberDevice
            )
        )
        if let error {
            throw error
        }
        return session
    }

    func requestEmailTwoFactorCode(for challenge: BitwardenTwoFactorLoginChallenge) async throws {
        emailCodeRequestCount += 1
        if let error {
            throw error
        }
    }
}

final class RecordingAppPlusPurchaseService: AppPlusPurchaseService, @unchecked Sendable {
    var products: [AppPlusProductInfo] = []
    var productsError: Error?
    var purchaseResult: PlusPurchaseResult = .purchased(productID: "com.monica.test.plus.support")
    var purchaseError: Error?
    var restoreEntitlement: PlusEntitlement = .inactive(verifiedAt: Date(timeIntervalSince1970: 0))
    var restoreError: Error?
    var currentEntitlementValue: PlusEntitlement = .inactive(verifiedAt: Date(timeIntervalSince1970: 0))

    private(set) var loadProductsCallCount = 0
    private(set) var purchasedProductIDs: [String] = []
    private(set) var restoreCallCount = 0
    private(set) var currentEntitlementCallCount = 0

    private let continuation: AsyncStream<PlusEntitlement>.Continuation
    let updatesStream: AsyncStream<PlusEntitlement>

    init() {
        var captured: AsyncStream<PlusEntitlement>.Continuation!
        updatesStream = AsyncStream { captured = $0 }
        continuation = captured
    }

    func send(_ entitlement: PlusEntitlement) {
        continuation.yield(entitlement)
    }

    func loadProducts() async throws -> [AppPlusProductInfo] {
        loadProductsCallCount += 1
        if let productsError {
            throw productsError
        }
        return products
    }

    func purchase(productID: String) async throws -> PlusPurchaseResult {
        purchasedProductIDs.append(productID)
        if let purchaseError {
            throw purchaseError
        }
        return purchaseResult
    }

    func restore() async throws -> PlusEntitlement {
        restoreCallCount += 1
        if let restoreError {
            throw restoreError
        }
        return restoreEntitlement
    }

    func currentEntitlement() async -> PlusEntitlement {
        currentEntitlementCallCount += 1
        return currentEntitlementValue
    }
}

struct RecordedKeePassKdbxFileReplacement: Equatable {
    let url: URL
    let data: Data
}

final class RecordingAppKeePassKdbxFileWritebackService: AppKeePassKdbxFileWritebackService, @unchecked Sendable {
    private(set) var replacements: [RecordedKeePassKdbxFileReplacement] = []
    var error: Error?

    func replaceFile(at url: URL, with data: Data) throws {
        replacements.append(RecordedKeePassKdbxFileReplacement(url: url, data: data))
        if let error {
            throw error
        }
    }
}

final class RecordingAndroidBackupAttachmentBlobStore: AndroidBackupAttachmentBlobStore, @unchecked Sendable {
    private(set) var savedBlobs: [RecordedAndroidBackupAttachmentBlob] = []

    func saveEncryptedBlob(_ data: Data, vaultID: String, localPath: String) throws -> String {
        savedBlobs.removeAll {
            $0.vaultID == vaultID && $0.localPath == localPath
        }
        savedBlobs.append(
            RecordedAndroidBackupAttachmentBlob(
                vaultID: vaultID,
                localPath: localPath,
                data: data
            )
        )
        return localPath
    }

    func encryptedBlobExists(vaultID: String, localPath: String) -> Bool {
        savedBlobs.contains {
            $0.vaultID == vaultID && $0.localPath == localPath
        }
    }

    func encryptedBlobData(vaultID: String, localPath: String) throws -> Data {
        guard let blob = savedBlobs.last(where: {
            $0.vaultID == vaultID && $0.localPath == localPath
        }) else {
            throw LocalAttachmentContentStoreError.missingBlob(localPath)
        }
        return blob.data
    }
}

struct RecordedAndroidBackupAttachmentBlob: Equatable {
    let vaultID: String
    let localPath: String
    let data: Data
}

final class RecordingKeePassDatabaseReader: KeePassDatabaseReader, @unchecked Sendable {
    struct Request: Equatable {
        let database: Data
        let sourceName: String?
        let credentials: KeePassUnlockCredentials
    }

    private(set) var requests: [Request] = []
    var snapshot: KeePassReadOnlySnapshot
    var error: Error?
    var queuedResults: [Result<KeePassReadOnlySnapshot, Error>] = []

    init(snapshot: KeePassReadOnlySnapshot) {
        self.snapshot = snapshot
    }

    func readSnapshot(
        database: Data,
        sourceName: String?,
        credentials: KeePassUnlockCredentials
    ) throws -> KeePassReadOnlySnapshot {
        requests.append(
            Request(
                database: database,
                sourceName: sourceName,
                credentials: credentials
            )
        )
        if !queuedResults.isEmpty {
            switch queuedResults.removeFirst() {
            case let .success(snapshot):
                return snapshot
            case let .failure(error):
                throw error
            }
        }
        if let error {
            throw error
        }
        return snapshot
    }

}

final class RecordingVaultEngine: LocalVaultEngine {
    private(set) var createdVaults: [RecordedVaultCall] = []
    private(set) var openedVaults: [RecordedVaultCall] = []
    private(set) var securityKeyOpenedVaults: [RecordedSecurityKeyVaultCall] = []
    private(set) var securityKeySetups: [RecordedSecurityKeySetupCall] = []
    private(set) var resetMasterPasswordCalls: [RecordedResetMasterPasswordCall] = []
    private(set) var verifiedMasterPasswords: [RecordedVaultCall] = []
    var createVaultError: Error?
    var openVaultError: Error?
    var verifyMasterPasswordError: Error?
    var updateTotpError: Error?
    var openVaultID = "opened-vault"
    var verifyMasterPasswordVaultID = "created-vault"
    var securityKeyOpenVaultID = "security-key-opened-vault"
    private(set) var createdProjects: [RecordedProjectCall] = []
    private(set) var renamedProjects: [RecordedRenamedProjectCall] = []
    private(set) var deletedProjects: [RecordedDeletedProjectCall] = []
    private(set) var movedVaultEntries: [RecordedMoveEntryCall] = []
    private(set) var createdLoginEntries: [RecordedLoginEntryCall] = []
    private(set) var updatedLoginEntries: [RecordedUpdatedLoginEntryCall] = []
    private(set) var favoritedLoginEntries: [RecordedFavoriteEntryCall] = []
    private(set) var iconUpdatedLoginEntries: [RecordedLoginIconCall] = []
    private(set) var deletedLoginEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredLoginEntries: [RecordedEntryMutationCall] = []
    private(set) var createdNoteEntries: [RecordedNoteEntryCall] = []
    private(set) var updatedNoteEntries: [RecordedUpdatedNoteEntryCall] = []
    private(set) var favoritedNoteEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedNoteEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredNoteEntries: [RecordedEntryMutationCall] = []
    private(set) var createdTotpEntries: [RecordedTotpEntryCall] = []
    private(set) var updatedTotpEntries: [RecordedUpdatedTotpEntryCall] = []
    private(set) var favoritedTotpEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedTotpEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredTotpEntries: [RecordedEntryMutationCall] = []
    private(set) var createdCardEntries: [RecordedCardEntryCall] = []
    private(set) var updatedCardEntries: [RecordedUpdatedCardEntryCall] = []
    private(set) var favoritedCardEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedCardEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredCardEntries: [RecordedEntryMutationCall] = []
    private(set) var createdIdentityEntries: [RecordedIdentityEntryCall] = []
    private(set) var updatedIdentityEntries: [RecordedUpdatedIdentityEntryCall] = []
    private(set) var favoritedIdentityEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedIdentityEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredIdentityEntries: [RecordedEntryMutationCall] = []
    private(set) var createdPasskeyEntries: [RecordedPasskeyEntryCall] = []
    private(set) var updatedPasskeyEntries: [RecordedUpdatedPasskeyEntryCall] = []
    private(set) var favoritedPasskeyEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedPasskeyEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredPasskeyEntries: [RecordedEntryMutationCall] = []
    private(set) var createdSshKeyEntries: [RecordedSshKeyEntryCall] = []
    private(set) var updatedSshKeyEntries: [RecordedUpdatedSshKeyEntryCall] = []
    private(set) var favoritedSshKeyEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedSshKeyEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredSshKeyEntries: [RecordedEntryMutationCall] = []
    private(set) var createdApiTokenEntries: [RecordedApiTokenEntryCall] = []
    private(set) var updatedApiTokenEntries: [RecordedUpdatedApiTokenEntryCall] = []
    private(set) var favoritedApiTokenEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedApiTokenEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredApiTokenEntries: [RecordedEntryMutationCall] = []
    private(set) var createdWifiEntries: [RecordedWifiEntryCall] = []
    private(set) var updatedWifiEntries: [RecordedUpdatedWifiEntryCall] = []
    private(set) var favoritedWifiEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedWifiEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredWifiEntries: [RecordedEntryMutationCall] = []
    private(set) var createdSendEntries: [RecordedSendEntryCall] = []
    private(set) var updatedSendEntries: [RecordedUpdatedSendEntryCall] = []
    private(set) var favoritedSendEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedSendEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredSendEntries: [RecordedEntryMutationCall] = []
    private(set) var createdAttachmentMetadata: [RecordedAttachmentMetadataCall] = []
    private(set) var updatedAttachmentMetadata: [RecordedUpdatedAttachmentMetadataCall] = []
    private var projects: [String: [LocalVaultProject]] = [:]
    private var loginEntries: [String: [LocalLoginEntry]] = [:]
    private var deletedEntries: [String: [LocalLoginEntry]] = [:]
    private var noteEntries: [String: [LocalNoteEntry]] = [:]
    private var deletedNotes: [String: [LocalNoteEntry]] = [:]
    private var totpEntries: [String: [LocalTotpEntry]] = [:]
    private var deletedTotp: [String: [LocalTotpEntry]] = [:]
    private var cardEntries: [String: [LocalCardEntry]] = [:]
    private var deletedCards: [String: [LocalCardEntry]] = [:]
    private var identityEntries: [String: [LocalIdentityEntry]] = [:]
    private var deletedIdentities: [String: [LocalIdentityEntry]] = [:]
    private var passkeyEntries: [String: [LocalPasskeyEntry]] = [:]
    private var deletedPasskeys: [String: [LocalPasskeyEntry]] = [:]
    /// #154：让 `createSshKeyEntry` 抛错，用来验证「私钥已写入但条目创建失败」时的回滚。
    var sshKeyCreationError: Error?
    private var sshKeyEntries: [String: [LocalSshKeyEntry]] = [:]
    private var deletedSshKeys: [String: [LocalSshKeyEntry]] = [:]
    private var apiTokenEntries: [String: [LocalApiTokenEntry]] = [:]
    private var ssoEntries: [String: [LocalSSOEntry]] = [:]
    private var deletedSSOEntries: [String: [LocalSSOEntry]] = [:]
    private var deletedApiTokens: [String: [LocalApiTokenEntry]] = [:]
    private var wifiEntries: [String: [LocalWifiEntry]] = [:]
    private var deletedWifi: [String: [LocalWifiEntry]] = [:]
    private var sendEntries: [String: [LocalSendEntry]] = [:]
    private var deletedSends: [String: [LocalSendEntry]] = [:]
    private var steamEntries: [String: [LocalSteamEntry]] = [:]
    private var deletedSteamEntries: [String: [LocalSteamEntry]] = [:]
    private var barcodeEntries: [String: [LocalBarcodeEntry]] = [:]
    private var deletedBarcodeEntries: [String: [LocalBarcodeEntry]] = [:]
    private var vaultFolderRecords: [String: [String: VaultFolderRecord]] = [:]
    private var gpgKeyEntries: [String: [LocalGPGKeyEntry]] = [:]
    private var deletedGPGKeyEntries: [String: [LocalGPGKeyEntry]] = [:]
    private var attachmentMetadata: [String: [LocalAttachmentMetadata]] = [:]
    private var deletedAttachmentMetadata: [String: [LocalAttachmentMetadata]] = [:]
    private var billingAddressEntries: [String: [LocalBillingAddressEntry]] = [:]
    private var deletedBillingAddressEntries: [String: [LocalBillingAddressEntry]] = [:]
    private var paymentAccountEntries: [String: [LocalPaymentAccountEntry]] = [:]
    private var deletedPaymentAccountEntries: [String: [LocalPaymentAccountEntry]] = [:]

    func seedAttachmentMetadata(_ metadata: LocalAttachmentMetadata, projectID: String) {
        attachmentMetadata[projectID, default: []].append(metadata)
    }

    func createVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle {
        createdVaults.append(.init(fileURL: fileURL, password: password, deviceID: deviceID))
        if let createVaultError {
            throw createVaultError
        }
        return LocalVaultHandle(vaultID: "created-vault", deviceID: deviceID)
    }

    func openVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle {
        openedVaults.append(.init(fileURL: fileURL, password: password, deviceID: deviceID))
        if let openVaultError {
            throw openVaultError
        }
        return LocalVaultHandle(vaultID: openVaultID, deviceID: deviceID)
    }

    func openVaultWithSecurityKey(
        at fileURL: URL,
        securityKeyMaterial: Data,
        deviceID: String
    ) throws -> LocalVaultHandle {
        securityKeyOpenedVaults.append(
            .init(fileURL: fileURL, keyMaterial: securityKeyMaterial, deviceID: deviceID)
        )
        if let openVaultError {
            throw openVaultError
        }
        return LocalVaultHandle(vaultID: securityKeyOpenVaultID, deviceID: deviceID)
    }

    func verifyMasterPassword(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle {
        verifiedMasterPasswords.append(
            .init(fileURL: fileURL, password: password, deviceID: deviceID)
        )
        if let verifyMasterPasswordError {
            throw verifyMasterPasswordError
        }
        return LocalVaultHandle(vaultID: verifyMasterPasswordVaultID, deviceID: deviceID)
    }

    func setupLocalSecurityKeyUnlock(
        in handle: LocalVaultHandle,
        securityKeyMaterial: Data
    ) throws {
        securityKeySetups.append(
            .init(vaultID: handle.vaultID, keyMaterial: securityKeyMaterial)
        )
    }

    func resetMasterPassword(
        in handle: LocalVaultHandle,
        newPassword: String
    ) throws {
        resetMasterPasswordCalls.append(
            .init(vaultID: handle.vaultID, newPassword: newPassword)
        )
    }

    func closeVault(_ handle: LocalVaultHandle) {}

    func seedExtendedParityEntries(projectID: String) {
        sshKeyEntries[projectID] = [
            LocalSshKeyEntry(
                id: "ssh-1",
                projectID: projectID,
                title: "Production deploy key",
                username: "deploy",
                host: "prod.example.com",
                publicKey: "ssh-ed25519 AAAA",
                privateKeyReference: "keychain://ssh/prod",
                passphraseHint: "1Password",
                notes: "Android parity SSH metadata",
                favorite: true
            )
        ]
        deletedSshKeys[projectID] = [
            LocalSshKeyEntry(
                id: "ssh-deleted-1",
                projectID: projectID,
                title: "Retired deploy key",
                username: "deploy",
                host: "old.example.com",
                publicKey: "ssh-ed25519 OLD",
                privateKeyReference: "keychain://ssh/old",
                passphraseHint: "",
                notes: ""
            )
        ]
        apiTokenEntries[projectID] = [
            LocalApiTokenEntry(
                id: "api-token-1",
                projectID: projectID,
                title: "Tiga API token",
                issuer: "Tiga",
                accountName: "joyin",
                token: "sk-secret",
                scopes: "sync,read",
                expiresAt: "2031-01-01",
                notes: "Keep secret"
            )
        ]
        deletedApiTokens[projectID] = [
            LocalApiTokenEntry(
                id: "api-token-deleted-1",
                projectID: projectID,
                title: "Old API token",
                issuer: "Tiga",
                accountName: "joyin",
                token: "sk-old",
                scopes: "read",
                expiresAt: "2026-01-01",
                notes: ""
            )
        ]
        wifiEntries[projectID] = [
            LocalWifiEntry(
                id: "wifi-1",
                projectID: projectID,
                title: "Studio Wi-Fi",
                ssid: "Monica Studio",
                securityType: "WPA2",
                password: "wifi-secret",
                hidden: false,
                notes: "Main office"
            )
        ]
        deletedWifi[projectID] = [
            LocalWifiEntry(
                id: "wifi-deleted-1",
                projectID: projectID,
                title: "Guest Wi-Fi",
                ssid: "Monica Guest",
                securityType: "WPA2",
                password: "guest-secret",
                hidden: false,
                notes: ""
            )
        ]
        sendEntries[projectID] = [
            LocalSendEntry(
                id: "send-1",
                projectID: projectID,
                title: "One-time send",
                body: "share once",
                expiresAt: "2026-06-02",
                maxViews: 1,
                notes: "MVP metadata"
            )
        ]
        deletedSends[projectID] = [
            LocalSendEntry(
                id: "send-deleted-1",
                projectID: projectID,
                title: "Expired send",
                body: "expired",
                expiresAt: "2026-01-01",
                maxViews: 1,
                notes: ""
            )
        ]
    }

    func createProject(
        in handle: LocalVaultHandle,
        title: String
    ) throws -> LocalVaultProject {
        createdProjects.append(.init(vaultID: handle.vaultID, title: title))
        let project = LocalVaultProject(id: "project-\(createdProjects.count)", title: title)
        projects[handle.vaultID, default: []].append(project)
        return project
    }

    func listProjects(in handle: LocalVaultHandle) throws -> [LocalVaultProject] {
        projects[handle.vaultID, default: []]
    }

    func renameProject(
        in handle: LocalVaultHandle,
        projectID: String,
        title: String
    ) throws -> LocalVaultProject {
        guard let index = projects[handle.vaultID, default: []].firstIndex(where: { $0.id == projectID }) else {
            throw LocalVaultRepositoryError.projectNotFound
        }
        let renamed = LocalVaultProject(id: projectID, title: title)
        renamedProjects.append(.init(vaultID: handle.vaultID, projectID: projectID, title: title))
        projects[handle.vaultID, default: []][index] = renamed
        return renamed
    }

    func deleteProject(in handle: LocalVaultHandle, projectID: String) throws {
        guard projects[handle.vaultID, default: []].contains(where: { $0.id == projectID }) else {
            throw LocalVaultRepositoryError.projectNotFound
        }
        guard !projectContainsEntries(projectID: projectID) else {
            throw LocalVaultRepositoryError.projectNotEmpty
        }
        deletedProjects.append(.init(vaultID: handle.vaultID, projectID: projectID))
        projects[handle.vaultID, default: []].removeAll { $0.id == projectID }
    }

    func moveEntry(
        in handle: LocalVaultHandle,
        kind: UnifiedVaultItemKind,
        entryID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws -> LocalVaultMovedEntry {
        movedVaultEntries.append(
            .init(
                vaultID: handle.vaultID,
                kind: kind,
                entryID: entryID,
                fromProjectID: fromProjectID,
                toProjectID: toProjectID
            )
        )

        switch kind {
        case .login:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &loginEntries, title: \.title) { entry, projectID in
                LocalLoginEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    username: entry.username,
                    password: entry.password,
                    url: entry.url,
                    favorite: entry.favorite
                )
            }
        case .note:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &noteEntries, title: \.title) { entry, projectID in
                LocalNoteEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    body: entry.body,
                    favorite: entry.favorite
                )
            }
        case .totp:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &totpEntries, title: \.title) { entry, projectID in
                LocalTotpEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    secret: entry.secret,
                    issuer: entry.issuer,
                    accountName: entry.accountName,
                    period: entry.period,
                    digits: entry.digits,
                    algorithm: entry.algorithm,
                    otpType: entry.otpType,
                    counter: entry.counter,
                    favorite: entry.favorite
                )
            }
        case .card:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &cardEntries, title: \.title) { entry, projectID in
                LocalCardEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    cardholderName: entry.cardholderName,
                    number: entry.number,
                    expiryMonth: entry.expiryMonth,
                    expiryYear: entry.expiryYear,
                    cvv: entry.cvv,
                    issuer: entry.issuer,
                    network: entry.network,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .identity:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &identityEntries, title: \.title) { entry, projectID in
                LocalIdentityEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    documentType: entry.documentType,
                    fullName: entry.fullName,
                    documentNumber: entry.documentNumber,
                    issuer: entry.issuer,
                    country: entry.country,
                    issueDate: entry.issueDate,
                    expiryDate: entry.expiryDate,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .passkey:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &passkeyEntries, title: \.title) { entry, projectID in
                LocalPasskeyEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    relyingPartyID: entry.relyingPartyID,
                    username: entry.username,
                    userHandle: entry.userHandle,
                    credentialID: entry.credentialID,
                    publicKeyCOSE: entry.publicKeyCOSE,
                    privateKeyReference: entry.privateKeyReference,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .sshKey:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &sshKeyEntries, title: \.title) { entry, projectID in
                LocalSshKeyEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    username: entry.username,
                    host: entry.host,
                    publicKey: entry.publicKey,
                    privateKeyReference: entry.privateKeyReference,
                    passphraseHint: entry.passphraseHint,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .apiToken:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &apiTokenEntries, title: \.title) { entry, projectID in
                LocalApiTokenEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    issuer: entry.issuer,
                    accountName: entry.accountName,
                    token: entry.token,
                    scopes: entry.scopes,
                    expiresAt: entry.expiresAt,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .wifi:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &wifiEntries, title: \.title) { entry, projectID in
                LocalWifiEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    ssid: entry.ssid,
                    securityType: entry.securityType,
                    password: entry.password,
                    hidden: entry.hidden,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .send:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &sendEntries, title: \.title) { entry, projectID in
                LocalSendEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    body: entry.body,
                    expiresAt: entry.expiresAt,
                    maxViews: entry.maxViews,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .sso:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &ssoEntries, title: \.title) { entry, projectID in
                LocalSSOEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    provider: entry.provider,
                    providerName: entry.providerName,
                    issuer: entry.issuer,
                    accountName: entry.accountName,
                    loginURL: entry.loginURL,
                    linkedLoginEntryID: entry.linkedLoginEntryID,
                    notes: entry.notes,
                    secret: entry.secret,
                    favorite: entry.favorite
                )
            }
        case .steam:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &steamEntries, title: \.title) { entry, projectID in
                LocalSteamEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    accountName: entry.accountName,
                    steamID: entry.steamID,
                    sharedSecret: entry.sharedSecret,
                    issuer: entry.issuer,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .barcode:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &barcodeEntries, title: \.title) { entry, projectID in
                LocalBarcodeEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    symbology: entry.symbology,
                    payload: entry.payload,
                    label: entry.label,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .billingAddress:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &billingAddressEntries, title: \.title) { entry, projectID in
                LocalBillingAddressEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    fullName: entry.fullName,
                    streetAddress: entry.streetAddress,
                    apartment: entry.apartment,
                    city: entry.city,
                    stateProvince: entry.stateProvince,
                    postalCode: entry.postalCode,
                    country: entry.country,
                    phone: entry.phone,
                    notes: entry.notes,
                    linkedCardIDs: entry.linkedCardIDs,
                    favorite: entry.favorite
                )
            }
        case .paymentAccount:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &paymentAccountEntries, title: \.title) { entry, projectID in
                LocalPaymentAccountEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    kind: entry.kind,
                    provider: entry.provider,
                    accountName: entry.accountName,
                    accountHolderName: entry.accountHolderName,
                    iban: entry.iban,
                    swiftBIC: entry.swiftBIC,
                    routingNumber: entry.routingNumber,
                    accountNumber: entry.accountNumber,
                    currency: entry.currency,
                    notes: entry.notes,
                    linkedCardID: entry.linkedCardID,
                    billingAddressID: entry.billingAddressID,
                    favorite: entry.favorite
                )
            }
        case .gpgKey:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &gpgKeyEntries, title: \.title) { entry, projectID in
                LocalGPGKeyEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    ownerName: entry.ownerName,
                    ownerEmail: entry.ownerEmail,
                    userID: entry.userID,
                    fingerprint: entry.fingerprint,
                    keyID: entry.keyID,
                    algorithm: entry.algorithm,
                    keyVersion: entry.keyVersion,
                    algorithmID: entry.algorithmID,
                    keyCreatedAt: entry.keyCreatedAt,
                    keyExpiresAt: entry.keyExpiresAt,
                    isRevoked: entry.isRevoked,
                    isSecretKey: entry.isSecretKey,
                    secretKeyIsEncrypted: entry.secretKeyIsEncrypted,
                    notes: entry.notes,
                    armoredPublicKey: entry.armoredPublicKey,
                    armoredPrivateKey: entry.armoredPrivateKey,
                    importedAt: entry.importedAt,
                    favorite: entry.favorite
                )
            }
        case .attachmentRef:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &attachmentMetadata, title: \.fileName) { entry, projectID in
                LocalAttachmentMetadata(
                    id: entry.id,
                    projectID: projectID,
                    entryID: entry.entryID,
                    fileName: entry.fileName,
                    mediaType: entry.mediaType,
                    originalSize: entry.originalSize,
                    storedSize: entry.storedSize,
                    contentHash: entry.contentHash,
                    storageMode: entry.storageMode,
                    source: entry.source,
                    downloadState: entry.downloadState,
                    wrappedContentEncryptionKey: entry.wrappedContentEncryptionKey,
                    localPath: entry.localPath,
                    deleted: entry.deleted
                )
            }
        }
    }

    private func moveRecordedEntry<Entry: Identifiable>(
        entryID: String,
        fromProjectID: String,
        toProjectID: String,
        kind: UnifiedVaultItemKind,
        entries: inout [String: [Entry]],
        title: KeyPath<Entry, String>,
        moving: (Entry, String) -> Entry
    ) throws -> LocalVaultMovedEntry where Entry.ID == String {
        guard var sourceEntries = entries[fromProjectID],
              let index = sourceEntries.firstIndex(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let entry = sourceEntries.remove(at: index)
        entries[fromProjectID] = sourceEntries
        let moved = moving(entry, toProjectID)
        entries[toProjectID, default: []].append(moved)
        return LocalVaultMovedEntry(id: moved.id, title: moved[keyPath: title], kind: kind)
    }

    func createLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let entry = LocalLoginEntry(
            id: "entry-\(createdLoginEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            username: draft.username,
            password: draft.password,
            url: draft.url,
            notes: draft.notes,
            urls: draft.urls,
            appBundleID: draft.appBundleID,
            appName: draft.appName,
            passwordHistory: draft.passwordHistory ?? []
        )
        createdLoginEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        loginEntries[projectID, default: []].append(entry)
        return entry
    }

    func listLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry] {
        loginEntries[projectID, default: []]
    }

    func updateLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let currentFavorite = loginEntries[projectID, default: []]
            .first(where: { $0.id == entryID })?
            .favorite ?? false
        let updated = LocalLoginEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            username: draft.username,
            password: draft.password,
            url: draft.url,
            notes: draft.notes,
            favorite: currentFavorite,
            urls: draft.urls,
            appBundleID: draft.appBundleID,
            appName: draft.appName,
            passwordHistory: draft.passwordHistory
                ?? loginEntries[projectID, default: []].first(where: { $0.id == entryID })?.passwordHistory
                ?? []
        )
        updatedLoginEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        loginEntries[projectID, default: []] = loginEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func setLoginEntryIcon(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        icon: String?
    ) throws -> LocalLoginEntry {
        iconUpdatedLoginEntries.append(
            .init(projectID: projectID, entryID: entryID, icon: icon)
        )
        guard let current = loginEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalLoginEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            username: current.username,
            password: current.password,
            url: current.url,
            notes: current.notes,
            favorite: current.favorite,
            icon: icon
        )
        loginEntries[projectID, default: []] = loginEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func setLoginEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalLoginEntry {
        favoritedLoginEntries.append(
            .init(
                vaultID: handle.vaultID,
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
        )
        guard let current = loginEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalLoginEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            username: current.username,
            password: current.password,
            url: current.url,
            notes: current.notes,
            favorite: favorite
        )
        loginEntries[projectID, default: []] = loginEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func deleteLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedLoginEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = loginEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        loginEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedEntries[projectID, default: []].append(entry)
    }

    func listDeletedLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry] {
        deletedEntries[projectID, default: []]
    }

    func restoreLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalLoginEntry {
        restoredLoginEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedEntries[projectID, default: []].removeAll { $0.id == entryID }
        loginEntries[projectID, default: []].append(entry)
        return entry
    }

    func createNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let entry = LocalNoteEntry(
            id: "note-\(createdNoteEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            body: draft.body
        )
        createdNoteEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        noteEntries[projectID, default: []].append(entry)
        return entry
    }

    func listNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry] {
        noteEntries[projectID, default: []]
    }

    func updateNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let currentFavorite = noteEntries[projectID, default: []]
            .first(where: { $0.id == entryID })?
            .favorite ?? false
        let updated = LocalNoteEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            body: draft.body,
            favorite: currentFavorite
        )
        updatedNoteEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        noteEntries[projectID, default: []] = noteEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func setNoteEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalNoteEntry {
        favoritedNoteEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite)
        )
        guard let current = noteEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalNoteEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            body: current.body,
            favorite: favorite
        )
        noteEntries[projectID, default: []] = noteEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func deleteNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedNoteEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = noteEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        noteEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedNotes[projectID, default: []].append(entry)
    }

    func listDeletedNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry] {
        deletedNotes[projectID, default: []]
    }

    func restoreNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalNoteEntry {
        restoredNoteEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedNotes[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedNotes[projectID, default: []].removeAll { $0.id == entryID }
        noteEntries[projectID, default: []].append(entry)
        return entry
    }

    func createTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let entry = LocalTotpEntry(
            id: "totp-\(createdTotpEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            secret: draft.secret,
            issuer: draft.issuer,
            accountName: draft.accountName,
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm,
            otpType: draft.otpType,
            counter: draft.counter,
            iconName: draft.iconName
        )
        createdTotpEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        totpEntries[projectID, default: []].append(entry)
        return entry
    }

    func listTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry] {
        totpEntries[projectID, default: []]
    }

    func updateTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        if let updateTotpError {
            throw updateTotpError
        }
        let currentFavorite = totpEntries[projectID, default: []]
            .first(where: { $0.id == entryID })?
            .favorite ?? false
        let updated = LocalTotpEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            secret: draft.secret,
            issuer: draft.issuer,
            accountName: draft.accountName,
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm,
            otpType: draft.otpType,
            counter: draft.counter,
            favorite: currentFavorite,
            iconName: draft.iconName
        )
        updatedTotpEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        totpEntries[projectID, default: []] = totpEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func setTotpEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalTotpEntry {
        favoritedTotpEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite)
        )
        guard let current = totpEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalTotpEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            secret: current.secret,
            issuer: current.issuer,
            accountName: current.accountName,
            period: current.period,
            digits: current.digits,
            algorithm: current.algorithm,
            otpType: current.otpType,
            counter: current.counter,
            favorite: favorite
        )
        totpEntries[projectID, default: []] = totpEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func deleteTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedTotpEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = totpEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        totpEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedTotp[projectID, default: []].append(entry)
    }

    func listDeletedTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry] {
        deletedTotp[projectID, default: []]
    }

    func restoreTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalTotpEntry {
        restoredTotpEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedTotp[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedTotp[projectID, default: []].removeAll { $0.id == entryID }
        totpEntries[projectID, default: []].append(entry)
        return entry
    }

    func createCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let entry = LocalCardEntry(
            id: "card-\(createdCardEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            cardholderName: draft.cardholderName,
            number: draft.number,
            expiryMonth: draft.expiryMonth,
            expiryYear: draft.expiryYear,
            cvv: draft.cvv,
            issuer: draft.issuer,
            network: draft.network,
            iban: draft.iban,
            swiftCode: draft.swiftCode,
            billingAddress: draft.billingAddress,
            cardArtwork: draft.cardArtwork,
            notes: draft.notes
        )
        createdCardEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        cardEntries[projectID, default: []].append(entry)
        return entry
    }

    func listCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry] {
        cardEntries[projectID, default: []]
    }

    func updateCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let currentFavorite = cardEntries[projectID, default: []]
            .first(where: { $0.id == entryID })?
            .favorite ?? false
        let updated = LocalCardEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            cardholderName: draft.cardholderName,
            number: draft.number,
            expiryMonth: draft.expiryMonth,
            expiryYear: draft.expiryYear,
            cvv: draft.cvv,
            issuer: draft.issuer,
            network: draft.network,
            iban: draft.iban,
            swiftCode: draft.swiftCode,
            billingAddress: draft.billingAddress,
            cardArtwork: draft.cardArtwork,
            notes: draft.notes,
            favorite: currentFavorite
        )
        updatedCardEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        cardEntries[projectID, default: []] = cardEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func setCardEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalCardEntry {
        favoritedCardEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite)
        )
        guard let current = cardEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalCardEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            cardholderName: current.cardholderName,
            number: current.number,
            expiryMonth: current.expiryMonth,
            expiryYear: current.expiryYear,
            cvv: current.cvv,
            issuer: current.issuer,
            network: current.network,
            notes: current.notes,
            favorite: favorite
        )
        cardEntries[projectID, default: []] = cardEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func deleteCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedCardEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = cardEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        cardEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedCards[projectID, default: []].append(entry)
    }

    func listDeletedCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry] {
        deletedCards[projectID, default: []]
    }

    func restoreCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalCardEntry {
        restoredCardEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedCards[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedCards[projectID, default: []].removeAll { $0.id == entryID }
        cardEntries[projectID, default: []].append(entry)
        return entry
    }

    func createIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let entry = LocalIdentityEntry(
            id: "identity-\(createdIdentityEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes
        )
        createdIdentityEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        identityEntries[projectID, default: []].append(entry)
        return entry
    }

    func listIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry] {
        identityEntries[projectID, default: []]
    }

    func updateIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let currentFavorite = identityEntries[projectID, default: []]
            .first(where: { $0.id == entryID })?
            .favorite ?? false
        let entry = LocalIdentityEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes,
            favorite: currentFavorite
        )
        updatedIdentityEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        identityEntries[projectID, default: []] = identityEntries[projectID, default: []].map {
            $0.id == entryID ? entry : $0
        }
        return entry
    }

    func setIdentityEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalIdentityEntry {
        favoritedIdentityEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite)
        )
        guard let current = identityEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalIdentityEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            documentType: current.documentType,
            fullName: current.fullName,
            documentNumber: current.documentNumber,
            issuer: current.issuer,
            country: current.country,
            issueDate: current.issueDate,
            expiryDate: current.expiryDate,
            notes: current.notes,
            favorite: favorite
        )
        identityEntries[projectID, default: []] = identityEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func deleteIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedIdentityEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = identityEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        identityEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedIdentities[projectID, default: []].append(entry)
    }

    func listDeletedIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry] {
        deletedIdentities[projectID, default: []]
    }

    func restoreIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalIdentityEntry {
        restoredIdentityEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedIdentities[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedIdentities[projectID, default: []].removeAll { $0.id == entryID }
        identityEntries[projectID, default: []].append(entry)
        return entry
    }

    func createPasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalPasskeyEntryDraft
    ) throws -> LocalPasskeyEntry {
        let entry = LocalPasskeyEntry(
            id: "passkey-\(createdPasskeyEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            relyingPartyID: draft.relyingPartyID,
            username: draft.username,
            userHandle: draft.userHandle,
            credentialID: draft.credentialID,
            publicKeyCOSE: draft.publicKeyCOSE,
            privateKeyReference: draft.privateKeyReference,
            notes: draft.notes
        )
        createdPasskeyEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        passkeyEntries[projectID, default: []].append(entry)
        return entry
    }

    func listPasskeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalPasskeyEntry] {
        passkeyEntries[projectID, default: []]
    }

    func updatePasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalPasskeyEntryDraft
    ) throws -> LocalPasskeyEntry {
        let currentFavorite = passkeyEntries[projectID, default: []]
            .first(where: { $0.id == entryID })?
            .favorite ?? false
        let updated = LocalPasskeyEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            relyingPartyID: draft.relyingPartyID,
            username: draft.username,
            userHandle: draft.userHandle,
            credentialID: draft.credentialID,
            publicKeyCOSE: draft.publicKeyCOSE,
            privateKeyReference: draft.privateKeyReference,
            notes: draft.notes,
            favorite: currentFavorite
        )
        updatedPasskeyEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        passkeyEntries[projectID, default: []] = passkeyEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func setPasskeyEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalPasskeyEntry {
        favoritedPasskeyEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite)
        )
        guard let current = passkeyEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalPasskeyEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            relyingPartyID: current.relyingPartyID,
            username: current.username,
            userHandle: current.userHandle,
            credentialID: current.credentialID,
            publicKeyCOSE: current.publicKeyCOSE,
            privateKeyReference: current.privateKeyReference,
            notes: current.notes,
            favorite: favorite
        )
        passkeyEntries[projectID, default: []] = passkeyEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func deletePasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedPasskeyEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = passkeyEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        passkeyEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedPasskeys[projectID, default: []].append(entry)
    }

    func listDeletedPasskeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalPasskeyEntry] {
        deletedPasskeys[projectID, default: []]
    }

    func restorePasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalPasskeyEntry {
        restoredPasskeyEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedPasskeys[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedPasskeys[projectID, default: []].removeAll { $0.id == entryID }
        passkeyEntries[projectID, default: []].append(entry)
        return entry
    }

    func createSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalSshKeyEntryDraft
    ) throws -> LocalSshKeyEntry {
        if let sshKeyCreationError {
            throw sshKeyCreationError
        }
        let entry = LocalSshKeyEntry(
            id: "ssh-\(createdSshKeyEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            username: draft.username,
            host: draft.host,
            publicKey: draft.publicKey,
            privateKeyReference: draft.privateKeyReference,
            passphraseHint: draft.passphraseHint,
            notes: draft.notes,
            algorithm: draft.algorithm,
            keySize: draft.keySize,
            fingerprint: draft.fingerprint
        )
        createdSshKeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, draft: draft))
        sshKeyEntries[projectID, default: []].append(entry)
        return entry
    }

    func updateSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalSshKeyEntryDraft
    ) throws -> LocalSshKeyEntry {
        let currentFavorite = sshKeyEntries[projectID, default: []].first(where: { $0.id == entryID })?.favorite ?? false
        let updated = LocalSshKeyEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            username: draft.username,
            host: draft.host,
            publicKey: draft.publicKey,
            privateKeyReference: draft.privateKeyReference,
            passphraseHint: draft.passphraseHint,
            notes: draft.notes,
            algorithm: draft.algorithm,
            keySize: draft.keySize,
            fingerprint: draft.fingerprint,
            favorite: currentFavorite
        )
        updatedSshKeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft))
        sshKeyEntries[projectID, default: []] = sshKeyEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func setSshKeyEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalSshKeyEntry {
        favoritedSshKeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite))
        guard let current = sshKeyEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalSshKeyEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            username: current.username,
            host: current.host,
            publicKey: current.publicKey,
            privateKeyReference: current.privateKeyReference,
            passphraseHint: current.passphraseHint,
            notes: current.notes,
            favorite: favorite
        )
        sshKeyEntries[projectID, default: []] = sshKeyEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func deleteSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedSshKeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = sshKeyEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        sshKeyEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedSshKeys[projectID, default: []].append(entry)
    }

    func restoreSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalSshKeyEntry {
        restoredSshKeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = deletedSshKeys[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedSshKeys[projectID, default: []].removeAll { $0.id == entryID }
        sshKeyEntries[projectID, default: []].append(entry)
        return entry
    }

    func createApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalApiTokenEntryDraft
    ) throws -> LocalApiTokenEntry {
        let entry = LocalApiTokenEntry(
            id: "api-token-\(createdApiTokenEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            issuer: draft.issuer,
            accountName: draft.accountName,
            token: draft.token,
            scopes: draft.scopes,
            expiresAt: draft.expiresAt,
            notes: draft.notes
        )
        createdApiTokenEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, draft: draft))
        apiTokenEntries[projectID, default: []].append(entry)
        return entry
    }

    func updateApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalApiTokenEntryDraft
    ) throws -> LocalApiTokenEntry {
        let currentFavorite = apiTokenEntries[projectID, default: []].first(where: { $0.id == entryID })?.favorite ?? false
        let updated = LocalApiTokenEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            issuer: draft.issuer,
            accountName: draft.accountName,
            token: draft.token,
            scopes: draft.scopes,
            expiresAt: draft.expiresAt,
            notes: draft.notes,
            favorite: currentFavorite
        )
        updatedApiTokenEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft))
        apiTokenEntries[projectID, default: []] = apiTokenEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func setApiTokenEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalApiTokenEntry {
        favoritedApiTokenEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite))
        guard let current = apiTokenEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalApiTokenEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            issuer: current.issuer,
            accountName: current.accountName,
            token: current.token,
            scopes: current.scopes,
            expiresAt: current.expiresAt,
            notes: current.notes,
            favorite: favorite
        )
        apiTokenEntries[projectID, default: []] = apiTokenEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func deleteApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedApiTokenEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = apiTokenEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        apiTokenEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedApiTokens[projectID, default: []].append(entry)
    }

    func restoreApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalApiTokenEntry {
        restoredApiTokenEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = deletedApiTokens[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedApiTokens[projectID, default: []].removeAll { $0.id == entryID }
        apiTokenEntries[projectID, default: []].append(entry)
        return entry
    }

    func createSSOEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalSSOEntryDraft
    ) throws -> LocalSSOEntry {
        let entry = LocalSSOEntry(
            id: "sso-\(ssoEntries[projectID, default: []].count + 1)",
            projectID: projectID,
            title: draft.title,
            provider: draft.provider,
            providerName: draft.providerName,
            issuer: draft.issuer,
            accountName: draft.accountName,
            loginURL: draft.loginURL,
            linkedLoginEntryID: draft.linkedLoginEntryID,
            notes: draft.notes,
            secret: draft.secret
        )
        ssoEntries[projectID, default: []].append(entry)
        return entry
    }

    func listSSOEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSSOEntry] {
        ssoEntries[projectID, default: []]
    }

    func updateSSOEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalSSOEntryDraft
    ) throws -> LocalSSOEntry {
        let currentFavorite = ssoEntries[projectID, default: []].first(where: { $0.id == entryID })?.favorite ?? false
        let updated = LocalSSOEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            provider: draft.provider,
            providerName: draft.providerName,
            issuer: draft.issuer,
            accountName: draft.accountName,
            loginURL: draft.loginURL,
            linkedLoginEntryID: draft.linkedLoginEntryID,
            notes: draft.notes,
            secret: draft.secret,
            favorite: currentFavorite
        )
        ssoEntries[projectID, default: []] = ssoEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func setSSOEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalSSOEntry {
        guard let current = ssoEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalSSOEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            provider: current.provider,
            providerName: current.providerName,
            issuer: current.issuer,
            accountName: current.accountName,
            loginURL: current.loginURL,
            linkedLoginEntryID: current.linkedLoginEntryID,
            notes: current.notes,
            secret: current.secret,
            favorite: favorite
        )
        ssoEntries[projectID, default: []] = ssoEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func deleteSSOEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        guard let entry = ssoEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        ssoEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedSSOEntries[projectID, default: []].append(entry)
    }

    func listDeletedSSOEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSSOEntry] {
        deletedSSOEntries[projectID, default: []]
    }

    func restoreSSOEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalSSOEntry {
        guard let entry = deletedSSOEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedSSOEntries[projectID, default: []].removeAll { $0.id == entryID }
        ssoEntries[projectID, default: []].append(entry)
        return entry
    }


    func createSteamEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalSteamEntryDraft
    ) throws -> LocalSteamEntry {
        let entry = LocalSteamEntry(
            id: "steam-\(steamEntries[projectID, default: []].count + 1)",
            projectID: projectID,
            title: draft.title,
            accountName: draft.accountName,
            steamID: draft.steamID,
            sharedSecret: draft.sharedSecret,
            issuer: draft.issuer,
            notes: draft.notes
        )
        steamEntries[projectID, default: []].append(entry)
        return entry
    }

    func listSteamEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSteamEntry] {
        steamEntries[projectID, default: []]
    }

    func updateSteamEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalSteamEntryDraft
    ) throws -> LocalSteamEntry {
        let currentFavorite = steamEntries[projectID, default: []].first(where: { $0.id == entryID })?.favorite ?? false
        let updated = LocalSteamEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            accountName: draft.accountName,
            steamID: draft.steamID,
            sharedSecret: draft.sharedSecret,
            issuer: draft.issuer,
            notes: draft.notes,
            favorite: currentFavorite
        )
        steamEntries[projectID, default: []] = steamEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func setSteamEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalSteamEntry {
        guard let current = steamEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalSteamEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            accountName: current.accountName,
            steamID: current.steamID,
            sharedSecret: current.sharedSecret,
            issuer: current.issuer,
            notes: current.notes,
            favorite: favorite
        )
        steamEntries[projectID, default: []] = steamEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func deleteSteamEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        guard let entry = steamEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        steamEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedSteamEntries[projectID, default: []].append(entry)
    }

    func listDeletedSteamEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSteamEntry] {
        deletedSteamEntries[projectID, default: []]
    }

    func restoreSteamEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalSteamEntry {
        guard let entry = deletedSteamEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedSteamEntries[projectID, default: []].removeAll { $0.id == entryID }
        steamEntries[projectID, default: []].append(entry)
        return entry
    }

    func listVaultFolderRecords(
        in handle: LocalVaultHandle,
        anchorProjectID: String
    ) throws -> [VaultFolderRecord] {
        (vaultFolderRecords[anchorProjectID] ?? [:]).values.sorted {
            if $0.sortOrder == $1.sortOrder { return $0.folderID < $1.folderID }
            return $0.sortOrder < $1.sortOrder
        }
    }

    func saveVaultFolderRecord(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        record: VaultFolderRecord
    ) throws {
        vaultFolderRecords[anchorProjectID, default: [:]][record.folderID] = record
    }

    func deleteVaultFolderRecord(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        folderID: String
    ) throws {
        vaultFolderRecords[anchorProjectID, default: [:]][folderID] = nil
    }

    func createBarcodeEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalBarcodeEntryDraft
    ) throws -> LocalBarcodeEntry {
        let entry = LocalBarcodeEntry(
            id: "barcode-\(barcodeEntries[projectID, default: []].count + 1)",
            projectID: projectID,
            draft: draft
        )
        barcodeEntries[projectID, default: []].append(entry)
        return entry
    }

    func listBarcodeEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalBarcodeEntry] {
        barcodeEntries[projectID, default: []]
    }

    func updateBarcodeEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalBarcodeEntryDraft
    ) throws -> LocalBarcodeEntry {
        let currentFavorite = barcodeEntries[projectID, default: []].first(where: { $0.id == entryID })?.favorite ?? false
        let updated = LocalBarcodeEntry(
            id: entryID,
            projectID: projectID,
            draft: draft,
            favorite: currentFavorite
        )
        barcodeEntries[projectID, default: []] = barcodeEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func setBarcodeEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalBarcodeEntry {
        guard let current = barcodeEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalBarcodeEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            symbology: current.symbology,
            payload: current.payload,
            label: current.label,
            notes: current.notes,
            favorite: favorite
        )
        barcodeEntries[projectID, default: []] = barcodeEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func deleteBarcodeEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        guard let entry = barcodeEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        barcodeEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedBarcodeEntries[projectID, default: []].append(entry)
    }

    func listDeletedBarcodeEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalBarcodeEntry] {
        deletedBarcodeEntries[projectID, default: []]
    }

    func restoreBarcodeEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalBarcodeEntry {
        guard let entry = deletedBarcodeEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedBarcodeEntries[projectID, default: []].removeAll { $0.id == entryID }
        barcodeEntries[projectID, default: []].append(entry)
        return entry
    }

    func createBillingAddressEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalBillingAddressEntryDraft
    ) throws -> LocalBillingAddressEntry {
        let entry = LocalBillingAddressEntry(
            id: UUID().uuidString,
            projectID: projectID,
            title: draft.title,
            fullName: draft.fullName,
            streetAddress: draft.streetAddress,
            apartment: draft.apartment,
            city: draft.city,
            stateProvince: draft.stateProvince,
            postalCode: draft.postalCode,
            country: draft.country,
            phone: draft.phone,
            notes: draft.notes,
            linkedCardIDs: draft.linkedCardIDs
        )
        billingAddressEntries[projectID, default: []].append(entry)
        return entry
    }

    func listBillingAddressEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalBillingAddressEntry] {
        billingAddressEntries[projectID, default: []]
    }

    func updateBillingAddressEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalBillingAddressEntryDraft
    ) throws -> LocalBillingAddressEntry {
        let currentFavorite = billingAddressEntries[projectID, default: []].first(where: { $0.id == entryID })?.favorite ?? false
        let updated = LocalBillingAddressEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            fullName: draft.fullName,
            streetAddress: draft.streetAddress,
            apartment: draft.apartment,
            city: draft.city,
            stateProvince: draft.stateProvince,
            postalCode: draft.postalCode,
            country: draft.country,
            phone: draft.phone,
            notes: draft.notes,
            linkedCardIDs: draft.linkedCardIDs,
            favorite: currentFavorite
        )
        billingAddressEntries[projectID, default: []] = billingAddressEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func setBillingAddressEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalBillingAddressEntry {
        guard let current = billingAddressEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalBillingAddressEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            fullName: current.fullName,
            streetAddress: current.streetAddress,
            apartment: current.apartment,
            city: current.city,
            stateProvince: current.stateProvince,
            postalCode: current.postalCode,
            country: current.country,
            phone: current.phone,
            notes: current.notes,
            linkedCardIDs: current.linkedCardIDs,
            favorite: favorite
        )
        billingAddressEntries[projectID, default: []] = billingAddressEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func deleteBillingAddressEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        guard let entry = billingAddressEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        billingAddressEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedBillingAddressEntries[projectID, default: []].append(entry)
    }

    func listDeletedBillingAddressEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalBillingAddressEntry] {
        deletedBillingAddressEntries[projectID, default: []]
    }

    func restoreBillingAddressEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalBillingAddressEntry {
        guard let entry = deletedBillingAddressEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedBillingAddressEntries[projectID, default: []].removeAll { $0.id == entryID }
        billingAddressEntries[projectID, default: []].append(entry)
        return entry
    }

    func createPaymentAccountEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalPaymentAccountEntryDraft
    ) throws -> LocalPaymentAccountEntry {
        let entry = LocalPaymentAccountEntry(
            id: UUID().uuidString,
            projectID: projectID,
            title: draft.title,
            kind: draft.kind,
            provider: draft.provider,
            accountName: draft.accountName,
            accountHolderName: draft.accountHolderName,
            iban: draft.iban,
            swiftBIC: draft.swiftBIC,
            routingNumber: draft.routingNumber,
            accountNumber: draft.accountNumber,
            currency: draft.currency,
            notes: draft.notes,
            linkedCardID: draft.linkedCardID,
            billingAddressID: draft.billingAddressID
        )
        paymentAccountEntries[projectID, default: []].append(entry)
        return entry
    }

    func listPaymentAccountEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalPaymentAccountEntry] {
        paymentAccountEntries[projectID, default: []]
    }

    func updatePaymentAccountEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalPaymentAccountEntryDraft
    ) throws -> LocalPaymentAccountEntry {
        let currentFavorite = paymentAccountEntries[projectID, default: []].first(where: { $0.id == entryID })?.favorite ?? false
        let updated = LocalPaymentAccountEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            kind: draft.kind,
            provider: draft.provider,
            accountName: draft.accountName,
            accountHolderName: draft.accountHolderName,
            iban: draft.iban,
            swiftBIC: draft.swiftBIC,
            routingNumber: draft.routingNumber,
            accountNumber: draft.accountNumber,
            currency: draft.currency,
            notes: draft.notes,
            linkedCardID: draft.linkedCardID,
            billingAddressID: draft.billingAddressID,
            favorite: currentFavorite
        )
        paymentAccountEntries[projectID, default: []] = paymentAccountEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func setPaymentAccountEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalPaymentAccountEntry {
        guard let current = paymentAccountEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalPaymentAccountEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            kind: current.kind,
            provider: current.provider,
            accountName: current.accountName,
            accountHolderName: current.accountHolderName,
            iban: current.iban,
            swiftBIC: current.swiftBIC,
            routingNumber: current.routingNumber,
            accountNumber: current.accountNumber,
            currency: current.currency,
            notes: current.notes,
            linkedCardID: current.linkedCardID,
            billingAddressID: current.billingAddressID,
            favorite: favorite
        )
        paymentAccountEntries[projectID, default: []] = paymentAccountEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func deletePaymentAccountEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        guard let entry = paymentAccountEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        paymentAccountEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedPaymentAccountEntries[projectID, default: []].append(entry)
    }

    func listDeletedPaymentAccountEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalPaymentAccountEntry] {
        deletedPaymentAccountEntries[projectID, default: []]
    }

    func restorePaymentAccountEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalPaymentAccountEntry {
        guard let entry = deletedPaymentAccountEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedPaymentAccountEntries[projectID, default: []].removeAll { $0.id == entryID }
        paymentAccountEntries[projectID, default: []].append(entry)
        return entry
    }

    func createGPGKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalGPGKeyEntryDraft
    ) throws -> LocalGPGKeyEntry {
        let entry = LocalGPGKeyEntry(
            id: "gpg-\(gpgKeyEntries[projectID, default: []].count + 1)",
            projectID: projectID,
            title: draft.title,
            ownerName: draft.metadata.ownerName,
            ownerEmail: draft.metadata.ownerEmail,
            userID: draft.metadata.userID,
            fingerprint: draft.metadata.fingerprint,
            keyID: draft.metadata.keyID,
            algorithm: draft.metadata.algorithm,
            keyVersion: draft.metadata.keyVersion,
            algorithmID: draft.metadata.algorithmID,
            keyCreatedAt: draft.metadata.keyCreatedAt,
            keyExpiresAt: draft.metadata.keyExpiresAt,
            isRevoked: draft.metadata.isRevoked,
            isSecretKey: draft.metadata.isSecretKey,
            secretKeyIsEncrypted: draft.metadata.secretKeyIsEncrypted,
            notes: draft.notes,
            armoredPublicKey: draft.armoredPublicKey,
            armoredPrivateKey: draft.armoredPrivateKey,
            importedAt: draft.importedAt,
            favorite: false
        )
        gpgKeyEntries[projectID, default: []].append(entry)
        return entry
    }

    func listGPGKeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalGPGKeyEntry] {
        gpgKeyEntries[projectID, default: []]
    }

    func updateGPGKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalGPGKeyEntryDraft
    ) throws -> LocalGPGKeyEntry {
        let currentFavorite = gpgKeyEntries[projectID, default: []].first(where: { $0.id == entryID })?.favorite ?? false
        let updated = LocalGPGKeyEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            ownerName: draft.metadata.ownerName,
            ownerEmail: draft.metadata.ownerEmail,
            userID: draft.metadata.userID,
            fingerprint: draft.metadata.fingerprint,
            keyID: draft.metadata.keyID,
            algorithm: draft.metadata.algorithm,
            keyVersion: draft.metadata.keyVersion,
            algorithmID: draft.metadata.algorithmID,
            keyCreatedAt: draft.metadata.keyCreatedAt,
            keyExpiresAt: draft.metadata.keyExpiresAt,
            isRevoked: draft.metadata.isRevoked,
            isSecretKey: draft.metadata.isSecretKey,
            secretKeyIsEncrypted: draft.metadata.secretKeyIsEncrypted,
            notes: draft.notes,
            armoredPublicKey: draft.armoredPublicKey,
            armoredPrivateKey: draft.armoredPrivateKey,
            importedAt: draft.importedAt,
            favorite: currentFavorite
        )
        gpgKeyEntries[projectID, default: []] = gpgKeyEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func setGPGKeyEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalGPGKeyEntry {
        guard let current = gpgKeyEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalGPGKeyEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            ownerName: current.ownerName,
            ownerEmail: current.ownerEmail,
            userID: current.userID,
            fingerprint: current.fingerprint,
            keyID: current.keyID,
            algorithm: current.algorithm,
            keyVersion: current.keyVersion,
            algorithmID: current.algorithmID,
            keyCreatedAt: current.keyCreatedAt,
            keyExpiresAt: current.keyExpiresAt,
            isRevoked: current.isRevoked,
            isSecretKey: current.isSecretKey,
            secretKeyIsEncrypted: current.secretKeyIsEncrypted,
            notes: current.notes,
            armoredPublicKey: current.armoredPublicKey,
            armoredPrivateKey: current.armoredPrivateKey,
            importedAt: current.importedAt,
            favorite: favorite
        )
        gpgKeyEntries[projectID, default: []] = gpgKeyEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func deleteGPGKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        guard let entry = gpgKeyEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        gpgKeyEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedGPGKeyEntries[projectID, default: []].append(entry)
    }

    func listDeletedGPGKeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalGPGKeyEntry] {
        deletedGPGKeyEntries[projectID, default: []]
    }

    func restoreGPGKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalGPGKeyEntry {
        guard let entry = deletedGPGKeyEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedGPGKeyEntries[projectID, default: []].removeAll { $0.id == entryID }
        gpgKeyEntries[projectID, default: []].append(entry)
        return entry
    }

    func createWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalWifiEntryDraft
    ) throws -> LocalWifiEntry {
        let entry = LocalWifiEntry(
            id: "wifi-\(createdWifiEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            ssid: draft.ssid,
            securityType: draft.securityType,
            password: draft.password,
            hidden: draft.hidden,
            notes: draft.notes
        )
        createdWifiEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, draft: draft))
        wifiEntries[projectID, default: []].append(entry)
        return entry
    }

    func updateWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalWifiEntryDraft
    ) throws -> LocalWifiEntry {
        let currentFavorite = wifiEntries[projectID, default: []].first(where: { $0.id == entryID })?.favorite ?? false
        let updated = LocalWifiEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            ssid: draft.ssid,
            securityType: draft.securityType,
            password: draft.password,
            hidden: draft.hidden,
            notes: draft.notes,
            favorite: currentFavorite
        )
        updatedWifiEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft))
        wifiEntries[projectID, default: []] = wifiEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func setWifiEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalWifiEntry {
        favoritedWifiEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite))
        guard let current = wifiEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalWifiEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            ssid: current.ssid,
            securityType: current.securityType,
            password: current.password,
            hidden: current.hidden,
            notes: current.notes,
            favorite: favorite
        )
        wifiEntries[projectID, default: []] = wifiEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func deleteWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedWifiEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = wifiEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        wifiEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedWifi[projectID, default: []].append(entry)
    }

    func restoreWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalWifiEntry {
        restoredWifiEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = deletedWifi[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedWifi[projectID, default: []].removeAll { $0.id == entryID }
        wifiEntries[projectID, default: []].append(entry)
        return entry
    }

    func createSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalSendEntryDraft
    ) throws -> LocalSendEntry {
        let entry = LocalSendEntry(
            id: "send-\(createdSendEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            body: draft.body,
            expiresAt: draft.expiresAt,
            maxViews: draft.maxViews,
            notes: draft.notes
        )
        createdSendEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, draft: draft))
        sendEntries[projectID, default: []].append(entry)
        return entry
    }

    func updateSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalSendEntryDraft
    ) throws -> LocalSendEntry {
        let currentFavorite = sendEntries[projectID, default: []].first(where: { $0.id == entryID })?.favorite ?? false
        let updated = LocalSendEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            body: draft.body,
            expiresAt: draft.expiresAt,
            maxViews: draft.maxViews,
            notes: draft.notes,
            favorite: currentFavorite
        )
        updatedSendEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft))
        sendEntries[projectID, default: []] = sendEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func setSendEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalSendEntry {
        favoritedSendEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite))
        guard let current = sendEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalSendEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            body: current.body,
            expiresAt: current.expiresAt,
            maxViews: current.maxViews,
            notes: current.notes,
            favorite: favorite
        )
        sendEntries[projectID, default: []] = sendEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func deleteSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedSendEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = sendEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        sendEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedSends[projectID, default: []].append(entry)
    }

    func restoreSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalSendEntry {
        restoredSendEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = deletedSends[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedSends[projectID, default: []].removeAll { $0.id == entryID }
        sendEntries[projectID, default: []].append(entry)
        return entry
    }

    func listSshKeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSshKeyEntry] {
        sshKeyEntries[projectID, default: []]
    }

    func listDeletedSshKeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSshKeyEntry] {
        deletedSshKeys[projectID, default: []]
    }

    func listApiTokenEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalApiTokenEntry] {
        apiTokenEntries[projectID, default: []]
    }

    func listDeletedApiTokenEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalApiTokenEntry] {
        deletedApiTokens[projectID, default: []]
    }

    func listWifiEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalWifiEntry] {
        wifiEntries[projectID, default: []]
    }

    func listDeletedWifiEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalWifiEntry] {
        deletedWifi[projectID, default: []]
    }

    func listSendEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSendEntry] {
        sendEntries[projectID, default: []]
    }

    func listDeletedSendEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSendEntry] {
        deletedSends[projectID, default: []]
    }

    func createAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String,
        downloadState: String,
        wrappedContentEncryptionKey: String?,
        localPath: String?
    ) throws -> LocalAttachmentMetadata {
        let metadata = LocalAttachmentMetadata(
            id: "attachment-\(createdAttachmentMetadata.count + 1)",
            projectID: projectID,
            entryID: entryID,
            fileName: fileName,
            mediaType: mediaType,
            originalSize: originalSize,
            storedSize: storedSize,
            contentHash: contentHash,
            storageMode: storageMode,
            source: source,
            downloadState: downloadState,
            wrappedContentEncryptionKey: wrappedContentEncryptionKey,
            localPath: localPath,
            deleted: false
        )
        createdAttachmentMetadata.append(
            .init(
                vaultID: handle.vaultID,
                projectID: projectID,
                entryID: entryID,
                fileName: fileName,
                mediaType: mediaType,
                originalSize: originalSize,
                storedSize: storedSize,
                contentHash: contentHash,
                storageMode: storageMode,
                source: source,
                downloadState: downloadState,
                wrappedContentEncryptionKey: wrappedContentEncryptionKey,
                localPath: localPath
            )
        )
        attachmentMetadata[projectID, default: []].append(metadata)
        return metadata
    }

    func listAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalAttachmentMetadata] {
        attachmentMetadata[projectID, default: []]
    }

    func updateAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String,
        downloadState: String,
        wrappedContentEncryptionKey: String?,
        localPath: String?
    ) throws -> LocalAttachmentMetadata {
        guard let index = attachmentMetadata[projectID, default: []].firstIndex(where: { $0.id == attachmentID }) else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        let metadata = LocalAttachmentMetadata(
            id: attachmentID,
            projectID: projectID,
            entryID: entryID,
            fileName: fileName,
            mediaType: mediaType,
            originalSize: originalSize,
            storedSize: storedSize,
            contentHash: contentHash,
            storageMode: storageMode,
            source: source,
            downloadState: downloadState,
            wrappedContentEncryptionKey: wrappedContentEncryptionKey,
            localPath: localPath,
            deleted: false
        )
        updatedAttachmentMetadata.append(
            .init(
                vaultID: handle.vaultID,
                projectID: projectID,
                attachmentID: attachmentID,
                entryID: entryID,
                fileName: fileName,
                mediaType: mediaType,
                originalSize: originalSize,
                storedSize: storedSize,
                contentHash: contentHash,
                storageMode: storageMode,
                source: source,
                downloadState: downloadState,
                wrappedContentEncryptionKey: wrappedContentEncryptionKey,
                localPath: localPath
            )
        )
        attachmentMetadata[projectID, default: []][index] = metadata
        return metadata
    }

    func deleteAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String
    ) throws {
        guard let index = attachmentMetadata[projectID, default: []].firstIndex(where: { $0.id == attachmentID }) else {
            return
        }
        let removed = attachmentMetadata[projectID, default: []].remove(at: index)
        deletedAttachmentMetadata[projectID, default: []].append(
            LocalAttachmentMetadata(
                id: removed.id,
                projectID: removed.projectID,
                entryID: removed.entryID,
                fileName: removed.fileName,
                mediaType: removed.mediaType,
                originalSize: removed.originalSize,
                storedSize: removed.storedSize,
                contentHash: removed.contentHash,
                storageMode: removed.storageMode,
                source: removed.source,
                downloadState: removed.downloadState,
                wrappedContentEncryptionKey: removed.wrappedContentEncryptionKey,
                localPath: removed.localPath,
                deleted: true
            )
        )
    }

    func listDeletedAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalAttachmentMetadata] {
        deletedAttachmentMetadata[projectID, default: []]
    }

    func restoreAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String
    ) throws -> LocalAttachmentMetadata {
        guard let index = deletedAttachmentMetadata[projectID, default: []].firstIndex(where: { $0.id == attachmentID }) else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        let removed = deletedAttachmentMetadata[projectID, default: []].remove(at: index)
        let restored = LocalAttachmentMetadata(
            id: removed.id,
            projectID: removed.projectID,
            entryID: removed.entryID,
            fileName: removed.fileName,
            mediaType: removed.mediaType,
            originalSize: removed.originalSize,
            storedSize: removed.storedSize,
            contentHash: removed.contentHash,
            storageMode: removed.storageMode,
            source: removed.source,
            downloadState: removed.downloadState,
            wrappedContentEncryptionKey: removed.wrappedContentEncryptionKey,
            localPath: removed.localPath,
            deleted: false
        )
        attachmentMetadata[projectID, default: []].append(restored)
        return restored
    }

    private func projectContainsEntries(projectID: String) -> Bool {
        !loginEntries[projectID, default: []].isEmpty
            || !deletedEntries[projectID, default: []].isEmpty
            || !noteEntries[projectID, default: []].isEmpty
            || !deletedNotes[projectID, default: []].isEmpty
            || !totpEntries[projectID, default: []].isEmpty
            || !deletedTotp[projectID, default: []].isEmpty
            || !cardEntries[projectID, default: []].isEmpty
            || !deletedCards[projectID, default: []].isEmpty
            || !identityEntries[projectID, default: []].isEmpty
            || !deletedIdentities[projectID, default: []].isEmpty
            || !passkeyEntries[projectID, default: []].isEmpty
            || !deletedPasskeys[projectID, default: []].isEmpty
            || !sshKeyEntries[projectID, default: []].isEmpty
            || !deletedSshKeys[projectID, default: []].isEmpty
            || !apiTokenEntries[projectID, default: []].isEmpty
            || !deletedApiTokens[projectID, default: []].isEmpty
            || !wifiEntries[projectID, default: []].isEmpty
            || !deletedWifi[projectID, default: []].isEmpty
            || !sendEntries[projectID, default: []].isEmpty
            || !deletedSends[projectID, default: []].isEmpty
            || !attachmentMetadata[projectID, default: []].isEmpty
            || !deletedAttachmentMetadata[projectID, default: []].isEmpty
    }
}

struct RecordedVaultCall {
    let fileURL: URL
    let password: String
    let deviceID: String
}

struct RecordedSecurityKeyVaultCall {
    let fileURL: URL
    let keyMaterial: Data
    let deviceID: String
}

struct RecordedSecurityKeySetupCall {
    let vaultID: String
    let keyMaterial: Data
}

struct RecordedResetMasterPasswordCall: Equatable {
    let vaultID: String
    let newPassword: String
}

struct RecordedProjectCall {
    let vaultID: String
    let title: String
}

struct RecordedRenamedProjectCall {
    let vaultID: String
    let projectID: String
    let title: String
}

struct RecordedDeletedProjectCall {
    let vaultID: String
    let projectID: String
}

struct RecordedMoveEntryCall {
    let vaultID: String
    let kind: UnifiedVaultItemKind
    let entryID: String
    let fromProjectID: String
    let toProjectID: String
}

struct RecordedLoginEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalLoginEntryDraft
}

struct RecordedUpdatedLoginEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalLoginEntryDraft
}

struct RecordedLoginIconCall: Equatable {
    let projectID: String
    let entryID: String
    let icon: String?
}

struct RecordedFavoriteEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let favorite: Bool
}

struct RecordedNoteEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalNoteEntryDraft
}

struct RecordedUpdatedNoteEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalNoteEntryDraft
}

struct RecordedTotpEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalTotpEntryDraft
}

struct RecordedUpdatedTotpEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalTotpEntryDraft
}

struct RecordedCardEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalCardEntryDraft
}

struct RecordedUpdatedCardEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalCardEntryDraft
}

struct RecordedIdentityEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalIdentityEntryDraft
}

struct RecordedUpdatedIdentityEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalIdentityEntryDraft
}

struct RecordedPasskeyEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalPasskeyEntryDraft
}

struct RecordedUpdatedPasskeyEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalPasskeyEntryDraft
}

struct RecordedSshKeyEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalSshKeyEntryDraft
}

struct RecordedUpdatedSshKeyEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalSshKeyEntryDraft
}

struct RecordedApiTokenEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalApiTokenEntryDraft
}

struct RecordedUpdatedApiTokenEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalApiTokenEntryDraft
}

struct RecordedWifiEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalWifiEntryDraft
}

struct RecordedUpdatedWifiEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalWifiEntryDraft
}

struct RecordedSendEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalSendEntryDraft
}

struct RecordedUpdatedSendEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalSendEntryDraft
}

struct RecordedAttachmentMetadataCall: Equatable {
    let vaultID: String
    let projectID: String
    let entryID: String?
    let fileName: String
    let mediaType: String
    let originalSize: Int64
    let storedSize: Int64
    let contentHash: String
    let storageMode: String
    let source: String
    let downloadState: String
    let wrappedContentEncryptionKey: String?
    let localPath: String?
}

struct RecordedUpdatedAttachmentMetadataCall: Equatable {
    let vaultID: String
    let projectID: String
    let attachmentID: String
    let entryID: String?
    let fileName: String
    let mediaType: String
    let originalSize: Int64
    let storedSize: Int64
    let contentHash: String
    let storageMode: String
    let source: String
    let downloadState: String
    let wrappedContentEncryptionKey: String?
    let localPath: String?
}

final class RecordingAppOneDriveAuthenticationService: AppOneDriveAuthenticationService, @unchecked Sendable {
    private let token: String
    private var accountLabel: String
    private var accountIdentifier: String
    private let signInError: Error?
    private var isSignedIn = false
    private(set) var accounts: [AppOneDriveAuthenticationSession]
    private(set) var signInCount = 0
    private(set) var switchedAccountIdentifiers: [String] = []
    private(set) var handledRedirects: [URL] = []

    init(
        token: String,
        accountLabel: String,
        accountIdentifier: String = "onedrive-account-a",
        accounts: [AppOneDriveAuthenticationSession]? = nil,
        signInError: Error? = nil,
        isSignedIn: Bool = false
    ) {
        self.token = token
        self.accountLabel = accountLabel
        self.accountIdentifier = accountIdentifier
        self.accounts = accounts ?? [AppOneDriveAuthenticationSession(
            accountLabel: accountLabel,
            accountIdentifier: accountIdentifier
        )]
        self.signInError = signInError
        self.isSignedIn = isSignedIn
    }

    func accessToken() async throws -> String {
        guard isSignedIn else {
            throw CloudFileProviderError.authenticationRequired(provider: .oneDrive)
        }
        return token
    }

    func restoreSession() async throws -> AppOneDriveAuthenticationSession? {
        guard isSignedIn else {
            return nil
        }
        return session()
    }

    func availableAccounts() async throws -> [AppOneDriveAuthenticationSession] {
        guard isSignedIn else {
            throw CloudFileProviderError.authenticationRequired(provider: .oneDrive)
        }
        return accounts
    }

    func switchAccount(identifier: String) async throws -> AppOneDriveAuthenticationSession {
        guard isSignedIn else {
            throw CloudFileProviderError.authenticationRequired(provider: .oneDrive)
        }
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let account = accounts.first(where: {
            $0.accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }) else {
            throw AppOneDriveAuthenticationError.accountUnavailable
        }
        switchAccountCount += 1
        switchedAccountIdentifiers.append(account.accountIdentifier.lowercased())
        accountLabel = account.accountLabel
        accountIdentifier = account.accountIdentifier
        return account
    }

    func signIn() async throws -> AppOneDriveAuthenticationSession {
        signInCount += 1
        if let signInError {
            throw signInError
        }
        isSignedIn = true
        return session()
    }

    func signOut() async throws {
        isSignedIn = false
    }

    private(set) var switchAccountCount = 0

    private func session() -> AppOneDriveAuthenticationSession {
        AppOneDriveAuthenticationSession(accountLabel: accountLabel, accountIdentifier: accountIdentifier)
    }

    func handleRedirectURL(_ url: URL) -> Bool {
        guard url.scheme == "msauth.com.monicapass.monica" else {
            return false
        }
        handledRedirects.append(url)
        return true
    }
}

final class AppTestOneDriveGraphTransport: OneDriveGraphTransport, @unchecked Sendable {
    private(set) var requests: [OneDriveGraphRequest] = []
    private var responses: [OneDriveGraphResponse] = []

    func enqueue(_ response: OneDriveGraphResponse) {
        responses.append(response)
    }

    func send(_ request: OneDriveGraphRequest) async throws -> OneDriveGraphResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
        }
        return responses.removeFirst()
    }
}

struct RecordedEntryMutationCall {
    let vaultID: String
    let projectID: String
    let entryID: String
}

func makeKdbx4Header(
    cipherID: Data,
    compressionFlags: Data,
    kdfParameters: Data
) -> Data {
    var data = Data([
        0x03, 0xD9, 0xA2, 0x9A,
        0x67, 0xFB, 0x4B, 0xB5,
        0x00, 0x00, 0x04, 0x00
    ])
    data.append(kdbx4HeaderField(id: 2, value: cipherID))
    data.append(kdbx4HeaderField(id: 3, value: compressionFlags))
    data.append(kdbx4HeaderField(id: 11, value: kdfParameters))
    data.append(kdbx4HeaderField(id: 0, value: Data([0x0D, 0x0A, 0x0D, 0x0A])))
    return data
}

func kdbx4HeaderField(id: UInt8, value: Data) -> Data {
    var field = Data([id])
    field.append(littleEndianUInt32(UInt32(value.count)))
    field.append(value)
    return field
}

func makeKdbxVariantDictionary(uuid: Data) -> Data {
    var data = Data([0x00, 0x01])
    data.append(kdbxVariantByteArray(key: "$UUID", value: uuid))
    data.append(Data([0x00]))
    return data
}

func kdbxVariantByteArray(key: String, value: Data) -> Data {
    var data = Data([0x42])
    let keyData = Data(key.utf8)
    data.append(littleEndianUInt32(UInt32(keyData.count)))
    data.append(keyData)
    data.append(littleEndianUInt32(UInt32(value.count)))
    data.append(value)
    return data
}

func littleEndianUInt32(_ value: UInt32) -> Data {
    var little = value.littleEndian
    return Data(bytes: &little, count: MemoryLayout<UInt32>.size)
}

func makeFastSecurityQuestionVerifier() -> SecurityQuestionAnswerVerifier {
    SecurityQuestionAnswerVerifier(
        hasher: SecurityQuestionAnswerHasher(
            parameters: .argon2id(timeCost: 1, memoryKiB: 1024, parallelism: 1)
        )
    )
}

func legacySecurityQuestionPayload(
    vaultID: String,
    answer1: String,
    answer2: String
) -> [String: Any] {
    [
        "vaultID": vaultID,
        "question1ID": 1,
        "question1Text": "第一题",
        "answer1Hash": SecurityQuestionAnswerVerifier.legacySHA256Hex(for: answer1),
        "question2ID": 3,
        "question2Text": "第二题",
        "answer2Hash": SecurityQuestionAnswerVerifier.legacySHA256Hex(for: answer2)
    ]
}

final class CorruptSecurityQuestionRecoveryStore: SecurityQuestionRecoveryStore, @unchecked Sendable {
    func save(_ setup: SecurityQuestionRecoverySetup) throws {}

    func load(vaultID: String) throws -> SecurityQuestionRecoverySetup? {
        throw SecurityQuestionCredentialError.corruptedStoredRecord
    }

    func delete(vaultID: String) throws {}
}


@MainActor
final class WidgetReloadCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

@MainActor
final class TotpRecordingPasteboard: SensitivePasteboardWriting {
    private(set) var changeCount = 0
    private(set) var content: String?
    private(set) var writeCount = 0

    var string: String? { content }

    func setString(_ value: String) {
        content = value
        changeCount += 1
        writeCount += 1
    }

    func clear() {
        content = nil
        changeCount += 1
    }
}

/// #154：可注入失败的 SSH 私钥存储，用来验证保存失败时的回滚。
final class SpySSHPrivateKeyStore: SSHPrivateKeyStore, @unchecked Sendable {
    private(set) var savedPrivateKeys: [String: String] = [:]
    private(set) var deletedReferences: [String] = []
    var saveError: Error?

    func savePrivateKey(_ privateKey: String, identifier: String) throws -> String {
        if let saveError {
            throw saveError
        }
        savedPrivateKeys[identifier] = privateKey
        return SSHPrivateKeyReference.reference(for: identifier)
    }

    func loadPrivateKey(reference: String) throws -> String? {
        guard let identifier = SSHPrivateKeyReference.identifier(from: reference) else {
            return nil
        }
        return savedPrivateKeys[identifier]
    }

    func deletePrivateKey(reference: String) throws {
        deletedReferences.append(reference)
        guard let identifier = SSHPrivateKeyReference.identifier(from: reference) else {
            return
        }
        savedPrivateKeys[identifier] = nil
    }
}
