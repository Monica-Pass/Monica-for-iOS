import Foundation
import Testing
@testable import MonicaSync

// MARK: - iCloud (CloudKit) provider tests (issue #76)
//
// These tests never touch CloudKit: `CloudKitCloudVaultRemoteStore` only speaks
// `CloudKitVaultTransport`, so the fake below stands in for the private database.
// The real `CloudKitContainerVaultTransport` needs a signed-in account, a
// provisioned container and a live network, none of which a unit test may assume.

private let cloudKitTestVaultID = "0f7c4f7a-2f2a-4c53-9d19-6f9a1c1e8b21"
private let cloudKitTestVaultName = "我的保险库"
private let cloudKitTestDeviceName = "iPhone 17"
private let cloudKitTestReferenceDate = Date(timeIntervalSince1970: 1_700_000_000)

private func cloudKitTestVaultData(_ seed: String = "encrypted-vault-v1") -> Data {
    Data(seed.utf8)
}

private func cloudKitTestSnapshot(
    data: Data,
    deviceID: String = "device-a",
    deviceName: String = cloudKitTestDeviceName,
    capturedAt: Date = cloudKitTestReferenceDate
) throws -> CloudVaultLocalSnapshot {
    try CloudVaultLocalSnapshot.make(
        vaultID: cloudKitTestVaultID,
        vaultName: cloudKitTestVaultName,
        data: data,
        deviceID: deviceID,
        deviceName: deviceName,
        capturedAt: capturedAt
    )
}

private func cloudKitTestManifest(revision: Int = 1, capturedAt: Date = cloudKitTestReferenceDate) throws -> (
    manifest: CloudVaultManifest, data: Data
) {
    let data = cloudKitTestVaultData()
    let snapshot = try cloudKitTestSnapshot(data: data, capturedAt: capturedAt)
    return (CloudVaultManifest.make(local: snapshot, revision: revision), data)
}

private func cloudKitTestConfiguration() throws -> CloudKitVaultConfiguration {
    try CloudKitVaultConfiguration.vault(vaultID: cloudKitTestVaultID)
}

// MARK: - Fake transport

private struct FakeStoredRecord {
    var payload: CloudKitRecordPayload
    var data: Data
    var changeTag: String
}

private struct FakeCloudKitState {
    var zoneExists = true
    var records: [String: FakeStoredRecord] = [:]
    var tagCounter = 0
    var pendingFailure: CloudKitVaultFailure?
    var availability: CloudKitAccountAvailability = .available
    var queuedChangeSets: [CloudKitZoneChangeSet] = []
    var savedPayloads: [CloudKitRecordPayload] = []
    var savedData: [Data] = []
    var saveCalls = 0
}

/// In-memory stand-in for the CloudKit private database.
private final class FakeCloudKitTransport: CloudKitVaultTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var state = FakeCloudKitState()

    private func mutate<T>(_ body: (inout FakeCloudKitState) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    private func consumeFailure(_ state: inout FakeCloudKitState) throws {
        if let failure = state.pendingFailure {
            state.pendingFailure = nil
            throw failure
        }
    }

    // MARK: Test controls

    func setZoneExists(_ exists: Bool) {
        mutate { $0.zoneExists = exists }
    }

    func setAvailability(_ availability: CloudKitAccountAvailability) {
        mutate { $0.availability = availability }
    }

    func failNext(_ failure: CloudKitVaultFailure) {
        mutate { $0.pendingFailure = failure }
    }

    func queueChangeSet(_ changeSet: CloudKitZoneChangeSet) {
        mutate { $0.queuedChangeSets.append(changeSet) }
    }

    /// Simulates another device writing the vault between two local operations.
    func simulateRemoteEdit(recordName: String, payload: CloudKitRecordPayload, data: Data) -> String {
        mutate { state in
            state.tagCounter += 1
            let tag = "tag-\(state.tagCounter)"
            state.records[recordName] = FakeStoredRecord(payload: payload, data: data, changeTag: tag)
            return tag
        }
    }

    func tamperStoredData(recordName: String, data: Data) {
        mutate { $0.records[recordName]?.data = data }
    }

    func storedData(recordName: String) -> Data? {
        mutate { $0.records[recordName]?.data }
    }

    func storedRecordNames() -> [String] {
        mutate { Array($0.records.keys).sorted() }
    }

    func savedPayloads() -> [CloudKitRecordPayload] {
        mutate { $0.savedPayloads }
    }

    func savedData() -> [Data] {
        mutate { $0.savedData }
    }

    func saveCount() -> Int {
        mutate { $0.saveCalls }
    }

    // MARK: CloudKitVaultTransport

    func accountAvailability() async throws -> CloudKitAccountAvailability {
        try mutate { state in
            try consumeFailure(&state)
            return state.availability
        }
    }

    func ensureZone(_ configuration: CloudKitVaultConfiguration) async throws {
        // Does not consume an injected failure: tests inject failures for the
        // operation under test (usually the save that follows zone creation).
        try mutate { $0.zoneExists = true }
    }

    func fetchRecord(
        _ configuration: CloudKitVaultConfiguration,
        recordName: String
    ) async throws -> CloudKitVaultRecord? {
        try mutate { state in
            try consumeFailure(&state)
            guard state.zoneExists else { throw CloudKitVaultFailure.zoneNotFound }
            guard let stored = state.records[recordName] else { throw CloudKitVaultFailure.recordNotFound }
            return CloudKitVaultRecord(
                recordName: recordName,
                changeTag: stored.changeTag,
                payload: stored.payload
            )
        }
    }

    func downloadAsset(
        _ configuration: CloudKitVaultConfiguration,
        recordName: String
    ) async throws -> Data {
        try mutate { state in
            try consumeFailure(&state)
            guard state.zoneExists else { throw CloudKitVaultFailure.zoneNotFound }
            guard let stored = state.records[recordName] else { throw CloudKitVaultFailure.recordNotFound }
            return stored.data
        }
    }

    func saveRecord(
        _ configuration: CloudKitVaultConfiguration,
        recordName: String,
        payload: CloudKitRecordPayload,
        vaultData: Data,
        condition: CloudKitSaveCondition
    ) async throws -> CloudKitVaultRecord {
        try mutate { state in
            try consumeFailure(&state)
            guard state.zoneExists else { throw CloudKitVaultFailure.zoneNotFound }
            switch condition {
            case .createOnly:
                if let existing = state.records[recordName] {
                    throw CloudKitVaultFailure.conflict(serverChangeTag: existing.changeTag)
                }
            case .ifUnchanged(let changeTag):
                guard let existing = state.records[recordName] else {
                    throw CloudKitVaultFailure.recordNotFound
                }
                guard existing.changeTag == changeTag else {
                    throw CloudKitVaultFailure.conflict(serverChangeTag: existing.changeTag)
                }
            case .replaceAll:
                break
            }
            state.tagCounter += 1
            let tag = "tag-\(state.tagCounter)"
            state.records[recordName] = FakeStoredRecord(payload: payload, data: vaultData, changeTag: tag)
            state.savedPayloads.append(payload)
            state.savedData.append(vaultData)
            state.saveCalls += 1
            return CloudKitVaultRecord(recordName: recordName, changeTag: tag, payload: payload)
        }
    }

    func fetchZoneChanges(
        _ configuration: CloudKitVaultConfiguration,
        since changeToken: Data?
    ) async throws -> CloudKitZoneChangeSet {
        try mutate { state in
            try consumeFailure(&state)
            guard state.zoneExists else { throw CloudKitVaultFailure.zoneNotFound }
            if !state.queuedChangeSets.isEmpty {
                return state.queuedChangeSets.removeFirst()
            }
            return CloudKitZoneChangeSet(
                changed: [],
                deletedRecordNames: [],
                changeToken: nil,
                didReset: false
            )
        }
    }
}

private func makeStore(
    _ transport: FakeCloudKitTransport
) throws -> CloudKitCloudVaultRemoteStore {
    CloudKitCloudVaultRemoteStore(configuration: try cloudKitTestConfiguration(), transport: transport)
}

private func captureCloudVaultError<T>(_ body: () async throws -> T) async -> CloudVaultError? {
    do {
        _ = try await body()
        return nil
    } catch let error as CloudVaultError {
        return error
    } catch {
        return nil
    }
}

// MARK: - Configuration

@Suite("iCloud CloudKit 保险库配置")
struct CloudKitVaultConfigurationTests {
    @Test("ASCII 保险库 ID 生成可预测且符合 CloudKit 命名的记录名")
    func recordNameIsDerivedFromVaultID() throws {
        let configuration = try cloudKitTestConfiguration()
        #expect(configuration.recordName == "monica-vault-\(cloudKitTestVaultID)")
        #expect(configuration.recordName.utf8.count <= CloudKitVaultSpec.maxRecordNameBytes)
        #expect(!configuration.recordName.hasPrefix("_"))
        #expect(configuration.zoneName == CloudKitVaultSpec.defaultZoneName)
        #expect(configuration.containerIdentifier == CloudKitVaultSpec.defaultContainerIdentifier)
        #expect(configuration.remotePath == "icloud://iCloud.ru.takagi.monica/MonicaVaultZone/monica-vault-\(cloudKitTestVaultID)")
    }

    @Test("非 ASCII 保险库 ID 退化为稳定的十六进制记录名")
    func nonASCIIVaultIDFallsBackToDigest() {
        let first = CloudKitVaultConfiguration.recordName(forVaultID: "保险库-42")
        let second = CloudKitVaultConfiguration.recordName(forVaultID: "保险库-42")
        #expect(first == second)
        #expect(first != "monica-vault-保险库-42")
        let token = first.replacingOccurrences(of: "monica-vault-", with: "")
        #expect(CloudVaultNaming.isLowercaseHex(token, count: token.count))
    }

    @Test("非法容器标识与记录区名称在构造时被拒绝")
    func invalidNamesAreRejected() {
        #expect(throws: CloudVaultError.self) {
            _ = try CloudKitVaultConfiguration(
                containerIdentifier: "com.example.not-icloud",
                zoneName: "MonicaVaultZone",
                recordName: "monica-vault-x"
            )
        }
        #expect(throws: CloudVaultError.self) {
            _ = try CloudKitVaultConfiguration(
                containerIdentifier: "iCloud.example.monica",
                zoneName: "_reserved",
                recordName: "monica-vault-x"
            )
        }
        #expect(throws: CloudVaultError.self) {
            _ = try CloudKitVaultConfiguration(
                containerIdentifier: "iCloud.example.monica",
                zoneName: "记录区",
                recordName: "monica-vault-x"
            )
        }
    }

    @Test("记录元数据只包含文档化的字段，绝不携带保险库/设备名")
    func payloadCarriesOnlyDocumentedFields() throws {
        let (manifest, _) = try cloudKitTestManifest()
        let payload = CloudKitRecordPayload(manifest: manifest)
        try payload.validate()
        let labels = Mirror(reflecting: payload).children.compactMap(\.label).sorted()
        #expect(labels == ["byteCount", "contentSHA256", "revision", "schemaVersion", "updatedAt", "vaultID"])
        #expect(labels.allSatisfy { !$0.lowercased().contains("name") })
        #expect(CloudKitVaultSpec.allowedRecordKeys.count == 7)
        #expect(!CloudKitVaultSpec.allowedRecordKeys.contains("vaultName"))
        #expect(!CloudKitVaultSpec.allowedRecordKeys.contains("deviceName"))
    }

    @Test("记录元数据拒绝缺失或损坏的清单")
    func payloadValidationRejectsCorruptMetadata() throws {
        let (manifest, _) = try cloudKitTestManifest()
        let badDigest = CloudKitRecordPayload(
            vaultID: manifest.vaultID,
            revision: 1,
            byteCount: manifest.byteCount,
            contentSHA256: "not-a-digest",
            updatedAt: manifest.updatedAt
        )
        #expect(throws: CloudVaultError.self) { try badDigest.validate() }

        let badRevision = CloudKitRecordPayload(
            vaultID: manifest.vaultID,
            revision: 0,
            byteCount: manifest.byteCount,
            contentSHA256: manifest.contentSHA256,
            updatedAt: manifest.updatedAt
        )
        #expect(throws: CloudVaultError.self) { try badRevision.validate() }

        let tooLarge = CloudKitRecordPayload(
            vaultID: manifest.vaultID,
            revision: 1,
            byteCount: CloudVaultProtocolSpec.maxVaultBytes + 1,
            contentSHA256: manifest.contentSHA256,
            updatedAt: manifest.updatedAt
        )
        #expect(throws: CloudVaultError.self) { try tooLarge.validate() }
    }
}

// MARK: - Store behaviour

@Suite("iCloud CloudKit 保险库读写")
struct CloudKitVaultStoreTests {
    @Test("没有记录时 readRemote 返回 nil（首次上传路径）")
    func readRemoteReturnsNilWithoutRecord() async throws {
        let transport = FakeCloudKitTransport()
        let store = try makeStore(transport)
        #expect(store.kind == .iCloud)
        #expect(store.displayName == "iCloud")
        let remote = try await store.readRemote()
        #expect(remote == nil)
    }

    @Test("记录区不存在时 readRemote 返回 nil 而不是错误")
    func missingZoneIsTreatedAsNoRemote() async throws {
        let transport = FakeCloudKitTransport()
        transport.setZoneExists(false)
        let store = try makeStore(transport)
        let remote = try await store.readRemote()
        #expect(remote == nil)
    }

    @Test("首次上传后可以读回同一份密文与清单，且清单中的名称被脱敏")
    func createAndReadRoundTrip() async throws {
        let transport = FakeCloudKitTransport()
        let store = try makeStore(transport)
        let (manifest, data) = try cloudKitTestManifest()

        let receipt = try await store.createRemote(vaultData: data, manifest: manifest)
        #expect(receipt.kind == .iCloud)
        #expect(receipt.manifestRevision == "1")
        #expect(receipt.revision == "tag-1")
        #expect(transport.storedData(recordName: receipt.fileName) == data)
        #expect(receipt.manifest.vaultName == CloudKitVaultSpec.redactedVaultName)
        #expect(receipt.manifest.updatedByDeviceName == CloudKitVaultSpec.redactedDeviceName)

        let remote = try #require(try await store.readRemote())
        #expect(remote.itemID == receipt.fileName)
        #expect(remote.revision == "tag-1")
        #expect(remote.manifestRevision == "1")
        #expect(remote.manifest.vaultID == manifest.vaultID)
        #expect(remote.manifest.contentSHA256 == manifest.contentSHA256)
        #expect(remote.manifest.byteCount == data.count)
        #expect(remote.manifest.revision == manifest.revision)
        #expect(remote.manifest.vaultName == CloudKitVaultSpec.redactedVaultName)
        #expect(remote.manifest.updatedByDeviceID == CloudKitVaultSpec.redactedDeviceID)
        try remote.manifest.validate()

        let downloaded = try await store.downloadVault(remote)
        #expect(downloaded == data)
    }

    @Test("更新使用读到的变更标记，成功后可再次读回")
    func updateUsesChangeTag() async throws {
        let transport = FakeCloudKitTransport()
        let store = try makeStore(transport)
        let (manifest, data) = try cloudKitTestManifest()
        _ = try await store.createRemote(vaultData: data, manifest: manifest)
        let remote = try #require(try await store.readRemote())

        let newData = cloudKitTestVaultData("encrypted-vault-v2")
        let snapshot = try cloudKitTestSnapshot(data: newData, capturedAt: cloudKitTestReferenceDate.addingTimeInterval(60))
        let newManifest = CloudVaultManifest.make(local: snapshot, revision: 2)
        let receipt = try await store.updateRemote(vaultData: newData, manifest: newManifest, remote: remote)

        #expect(receipt.manifestRevision == "2")
        #expect(receipt.revision != remote.revision)
        #expect(transport.saveCount() == 2)
        #expect(transport.savedData().last == newData)

        let updated = try #require(try await store.readRemote())
        #expect(updated.manifestRevision == "2")
        #expect(updated.manifest.contentSHA256 == newManifest.contentSHA256)
    }

    @Test("变更标记过期（另一端已写）时更新被拒绝并报告云端版本")
    func staleChangeTagIsRefused() async throws {
        let transport = FakeCloudKitTransport()
        let store = try makeStore(transport)
        let (manifest, data) = try cloudKitTestManifest()
        let receipt = try await store.createRemote(vaultData: data, manifest: manifest)
        let remote = try #require(try await store.readRemote())

        let otherData = cloudKitTestVaultData("other-device")
        let serverTag = transport.simulateRemoteEdit(
            recordName: receipt.fileName,
            payload: CloudKitRecordPayload(manifest: manifest),
            data: otherData
        )
        #expect(serverTag != remote.revision)

        let newData = cloudKitTestVaultData("encrypted-vault-v2")
        let snapshot = try cloudKitTestSnapshot(data: newData)
        let newManifest = CloudVaultManifest.make(local: snapshot, revision: 2)
        let error = await captureCloudVaultError {
            try await store.updateRemote(vaultData: newData, manifest: newManifest, remote: remote)
        }
        guard case .preconditionFailed(let remoteRevision) = error else {
            Issue.record("expected preconditionFailed, got \(String(describing: error))")
            return
        }
        #expect(remoteRevision == serverTag)
        #expect(transport.storedData(recordName: receipt.fileName) == otherData)
    }

    @Test("没有变更标记时拒绝写入，避免无条件覆盖")
    func updateWithoutChangeTagIsRefused() async throws {
        let transport = FakeCloudKitTransport()
        let store = try makeStore(transport)
        let (manifest, data) = try cloudKitTestManifest()
        let receipt = try await store.createRemote(vaultData: data, manifest: manifest)

        let remoteWithoutTag = CloudVaultRemoteFile(
            kind: .iCloud,
            remotePath: receipt.remotePath,
            fileName: receipt.fileName,
            manifestFileName: receipt.manifestFileName,
            itemID: receipt.itemID,
            revision: nil,
            manifestRevision: receipt.manifestRevision,
            manifest: receipt.manifest
        )
        let error = await captureCloudVaultError {
            try await store.updateRemote(vaultData: data, manifest: manifest, remote: remoteWithoutTag)
        }
        #expect(error == .preconditionFailed(remoteRevision: nil))
        #expect(transport.saveCount() == 1)
    }

    @Test("上传前校验密文摘要，不匹配时一个字节都不写")
    func createRefusesMismatchedCiphertext() async throws {
        let transport = FakeCloudKitTransport()
        let store = try makeStore(transport)
        let (manifest, _) = try cloudKitTestManifest()
        let tampered = cloudKitTestVaultData("tampered")

        let error = await captureCloudVaultError {
            try await store.createRemote(vaultData: tampered, manifest: manifest)
        }
        guard case .integrityMismatch = error else {
            Issue.record("expected integrityMismatch, got \(String(describing: error))")
            return
        }
        #expect(transport.saveCount() == 0)
        #expect(transport.storedRecordNames().isEmpty)
    }

    @Test("下载时校验密文摘要，被篡改的云端数据不会被接受")
    func downloadDetectsTamperedCiphertext() async throws {
        let transport = FakeCloudKitTransport()
        let store = try makeStore(transport)
        let (manifest, data) = try cloudKitTestManifest()
        let receipt = try await store.createRemote(vaultData: data, manifest: manifest)
        transport.tamperStoredData(recordName: receipt.fileName, data: cloudKitTestVaultData("server-side-tamper"))
        let remote = try #require(try await store.readRemote())

        let error = await captureCloudVaultError {
            try await store.downloadVault(remote)
        }
        guard case .integrityMismatch(let expected, let actual) = error else {
            Issue.record("expected integrityMismatch, got \(String(describing: error))")
            return
        }
        #expect(expected == manifest.contentSHA256)
        #expect(actual != expected)
    }

    @Test("云端记录缺失时下载报告 remoteVaultMissing")
    func downloadMissingRecord() async throws {
        let transport = FakeCloudKitTransport()
        let store = try makeStore(transport)
        let (manifest, data) = try cloudKitTestManifest()
        let receipt = try await store.createRemote(vaultData: data, manifest: manifest)
        let remote = try #require(try await store.readRemote())
        transport.setZoneExists(false)

        let error = await captureCloudVaultError {
            try await store.downloadVault(remote)
        }
        #expect(error == .remoteVaultMissing)
        #expect(receipt.fileName == remote.fileName)
    }

    @Test("冲突副本写为独立记录，名称确定且为 ASCII")
    func conflictCopyUsesSeparateDeterministicRecord() async throws {
        let transport = FakeCloudKitTransport()
        let store = try makeStore(transport)
        let (manifest, data) = try cloudKitTestManifest()
        _ = try await store.createRemote(vaultData: data, manifest: manifest)

        let now = cloudKitTestReferenceDate
        let receipt = try await store.writeConflictCopy(
            vaultData: data,
            manifest: manifest,
            deviceName: cloudKitTestDeviceName,
            now: now
        )
        #expect(receipt.fileName.hasPrefix(CloudKitVaultSpec.conflictCopyPrefix))
        let isASCII = receipt.fileName.unicodeScalars.allSatisfy(\.isASCII)
        #expect(isASCII)
        #expect(!receipt.fileName.contains("iphone"))
        #expect(receipt.fileName.utf8.count <= CloudKitVaultSpec.maxRecordNameBytes)
        #expect(transport.storedData(recordName: receipt.fileName) == data)

        // A retry of the same conflict resolution must not create a second record.
        _ = try await store.writeConflictCopy(
            vaultData: data,
            manifest: manifest,
            deviceName: cloudKitTestDeviceName,
            now: now
        )
        let conflictCopies = transport.storedRecordNames().filter {
            $0.hasPrefix(CloudKitVaultSpec.conflictCopyPrefix)
        }
        #expect(conflictCopies == [receipt.fileName])
    }

    @Test("增量拉取返回变更、删除与新的变更令牌")
    func changePollingReturnsChanges() async throws {
        let transport = FakeCloudKitTransport()
        let store = try makeStore(transport)
        let (manifest, data) = try cloudKitTestManifest()
        let receipt = try await store.createRemote(vaultData: data, manifest: manifest)

        let token = Data("token-1".utf8)
        let newToken = Data("token-2".utf8)
        transport.queueChangeSet(
            CloudKitZoneChangeSet(
                changed: [
                    CloudKitVaultRecord(
                        recordName: receipt.fileName,
                        changeTag: "tag-9",
                        payload: CloudKitRecordPayload(manifest: manifest)
                    )
                ],
                deletedRecordNames: ["monica-cloud-conflict-old"],
                changeToken: newToken,
                didReset: false
            )
        )

        let changes = try await store.pollChanges(since: token)
        #expect(changes.changed.count == 1)
        #expect(changes.changed.first?.recordName == receipt.fileName)
        #expect(changes.deletedRecordNames == ["monica-cloud-conflict-old"])
        #expect(changes.changeToken == newToken)
        #expect(!changes.didReset)

        let empty = try await store.pollChanges(since: newToken)
        #expect(empty.isEmpty)
    }

    @Test("变更令牌过期时返回 didReset，调用方可以丢弃缓存")
    func changePollingReportsReset() async throws {
        let transport = FakeCloudKitTransport()
        let store = try makeStore(transport)
        transport.queueChangeSet(
            CloudKitZoneChangeSet(changed: [], deletedRecordNames: [], changeToken: Data("fresh".utf8), didReset: true)
        )
        let changes = try await store.pollChanges(since: Data("expired".utf8))
        #expect(changes.didReset)
        #expect(changes.changeToken == Data("fresh".utf8))
    }

    @Test("云端还没创建 zone 时，检查变更视为没有变更")
    func changePollingBeforeFirstUploadIsEmpty() async throws {
        let transport = FakeCloudKitTransport()
        transport.setZoneExists(false)
        let store = try makeStore(transport)
        let changes = try await store.pollChanges(since: nil)
        #expect(changes.isEmpty)
        #expect(changes.changeToken == nil)
        #expect(!changes.didReset)
    }

    @Test("账号可用性透传 CloudKit 的状态")
    func accountAvailabilityIsForwarded() async throws {
        let transport = FakeCloudKitTransport()
        let store = try makeStore(transport)
        let available = try await store.accountAvailability()
        #expect(available == .available)
        transport.setAvailability(.noAccount)
        let missing = try await store.accountAvailability()
        #expect(missing == .noAccount)
    }
}

// MARK: - Error mapping

@Suite("iCloud CloudKit 错误映射")
struct CloudKitVaultErrorMappingTests {
    private func errorFor(_ failure: CloudKitVaultFailure) async throws -> CloudVaultError? {
        let transport = FakeCloudKitTransport()
        let store = try makeStore(transport)
        transport.failNext(failure)
        return await captureCloudVaultError { try await store.readRemote() }
    }

    @Test("未登录 iCloud 映射为 cloudAccountUnavailable")
    func notAuthenticated() async throws {
        let error = try await errorFor(.notAuthenticated)
        #expect(error == .cloudAccountUnavailable(.iCloud))
    }

    @Test("账号暂时不可用映射为 cloudAccountUnavailable")
    func accountTemporarilyUnavailable() async throws {
        let error = try await errorFor(.accountTemporarilyUnavailable)
        #expect(error == .cloudAccountUnavailable(.iCloud))
    }

    @Test("缺少 entitlement 或容器无效映射为 notConfigured")
    func configureFailures() async throws {
        if case .notConfigured = try await errorFor(.missingEntitlement) {} else {
            Issue.record("missingEntitlement should map to notConfigured")
        }
        if case .notConfigured = try await errorFor(.badContainer) {} else {
            Issue.record("badContainer should map to notConfigured")
        }
    }

    @Test("存储空间不足映射为 cloudQuotaExceeded")
    func quotaExceeded() async throws {
        let error = try await errorFor(.quotaExceeded)
        #expect(error == .cloudQuotaExceeded(.iCloud))
    }

    @Test("网络错误映射为可重试的 network")
    func networkFailure() async throws {
        let error = try await errorFor(.networkUnavailable("The network connection was lost."))
        guard case .network(let message) = error else {
            Issue.record("expected network, got \(String(describing: error))")
            return
        }
        #expect(message.contains("network"))
        #expect(error?.isRetryable == true)
    }

    @Test("权限不足映射为 forbidden")
    func permissionDenied() async throws {
        let error = try await errorFor(.permissionDenied)
        #expect(error == .forbidden(.iCloud))
    }

    @Test("云端记录缺少文件映射为 remoteVaultMissing")
    func assetUnavailable() async throws {
        let error = try await errorFor(.assetUnavailable("gone"))
        #expect(error == .remoteVaultMissing)
    }

    @Test("服务端拒绝与无法解析的记录分别映射为 server 与 manifestInvalid")
    func rejectionAndMalformed() async throws {
        if case .server(let statusCode, _) = try await errorFor(.rejected("record rejected")) {
            #expect(statusCode == 400)
        } else {
            Issue.record("rejected should map to server")
        }
        if case .manifestInvalid = try await errorFor(.malformed("missing field")) {} else {
            Issue.record("malformed should map to manifestInvalid")
        }
    }

    @Test("超过 CloudKit 大小限制时按字节数报告 vaultTooLarge")
    func limitExceededOnSave() async throws {
        let transport = FakeCloudKitTransport()
        let store = try makeStore(transport)
        let (manifest, data) = try cloudKitTestManifest()
        transport.failNext(.limitExceeded)
        let error = await captureCloudVaultError {
            try await store.createRemote(vaultData: data, manifest: manifest)
        }
        #expect(error == .vaultTooLarge(byteCount: data.count))
    }

    @Test("iCloud 错误带有固定的诊断码与 provider 标签")
    func diagnosticsAreStable() async throws {
        let quota = CloudVaultError.cloudQuotaExceeded(.iCloud)
        let account = CloudVaultError.cloudAccountUnavailable(.iCloud)
        #expect(quota.diagnosticCode.rawValue == "SYNC-1023")
        #expect(quota.diagnosticReason.rawValue == "storage")
        #expect(account.diagnosticCode.rawValue == "SYNC-1013")
        #expect(account.diagnosticReason.rawValue == "unauthorized")
        #expect(CloudVaultRemoteKind.iCloud.diagnosticProviderTag.rawValue == "iCloud")
    }

    @Test("配额失败保持待上传标记，账号失效则清除")
    func failureBookkeeping() throws {
        let engine = CloudVaultSyncEngine()
        let record = CloudVaultSyncRecord(
            key: CloudVaultSyncRecord.key(remoteKind: .iCloud, remotePath: "icloud://x/y/z", vaultID: cloudKitTestVaultID),
            vaultID: cloudKitTestVaultID,
            remoteKind: .iCloud,
            remotePath: "icloud://x/y/z"
        )
        #expect(engine.recordFailure(CloudVaultError.cloudQuotaExceeded(.iCloud), in: record).pendingUpload)
        #expect(!engine.recordFailure(CloudVaultError.cloudAccountUnavailable(.iCloud), in: record).pendingUpload)
        #expect(engine.recordFailure(CloudVaultError.network("offline"), in: record).pendingUpload)
    }
}

// MARK: - Engine integration

@Suite("iCloud 保险库与同步引擎对接")
struct CloudKitVaultEngineTests {
    @Test("设备 A 上传、设备 B 首次拉取、B 再上传、A 拉回（同一份假云端）")
    func twoDeviceManualSync() async throws {
        let transport = FakeCloudKitTransport()
        let engineA = CloudVaultSyncEngine()
        let storeA = try makeStore(transport)
        let dataA = cloudKitTestVaultData("vault-a")
        let snapshotA = try cloudKitTestSnapshot(data: dataA, deviceID: "device-a")

        let decision = engineA.plan(local: snapshotA, record: nil, remote: nil)
        #expect(decision == .pushNew)
        let pushA = try #require(try await engineA.push(local: snapshotA, store: storeA, record: nil))
        #expect(pushA.receipt.manifestRevision == "1")

        // Device B restores without any local baseline.
        let engineB = CloudVaultSyncEngine()
        let storeB = try makeStore(transport)
        let freshRecordB = CloudVaultSyncRecord(
            key: CloudVaultSyncRecord.key(remoteKind: .iCloud, remotePath: storeB.remotePath, vaultID: cloudKitTestVaultID),
            vaultID: cloudKitTestVaultID,
            remoteKind: .iCloud,
            remotePath: storeB.remotePath
        )
        let pullB = try #require(try await engineB.pull(store: storeB, record: freshRecordB))
        #expect(pullB.vaultData == dataA)
        #expect(pullB.remote.manifest.revision == 1)
        let appliedB = try engineB.confirmPullApplied(pullB)

        // B edits and pushes revision 2.
        let dataB = cloudKitTestVaultData("vault-b")
        let snapshotB = try cloudKitTestSnapshot(
            data: dataB,
            deviceID: "device-b",
            capturedAt: cloudKitTestReferenceDate.addingTimeInterval(120)
        )
        let pushB = try #require(try await engineB.push(local: snapshotB, store: storeB, record: appliedB))
        #expect(pushB.receipt.manifestRevision == "2")

        // A pulls the new revision without touching its own bytes until commit.
        let pullA = try #require(try await engineA.pull(store: storeA, record: pushA.record))
        #expect(pullA.vaultData == dataB)
        #expect(pullA.remote.manifest.revision == 2)
    }

    @Test("两端同时修改时引擎要求显式解决冲突，云端保持不变")
    func simultaneousEditsNeedResolution() async throws {
        let transport = FakeCloudKitTransport()
        let engineA = CloudVaultSyncEngine()
        let engineB = CloudVaultSyncEngine()
        let storeA = try makeStore(transport)
        let storeB = try makeStore(transport)

        // Shared baseline: A uploads revision 1 and B pulls it.
        let baseData = cloudKitTestVaultData("base")
        let baseSnapshot = try cloudKitTestSnapshot(data: baseData, deviceID: "device-a")
        let pushBase = try #require(try await engineA.push(local: baseSnapshot, store: storeA, record: nil))
        let baselineB = try engineB.confirmPullApplied(
            try #require(
                try await engineB.pull(
                    store: storeB,
                    record: CloudVaultSyncRecord(
                        key: CloudVaultSyncRecord.key(remoteKind: .iCloud, remotePath: storeB.remotePath, vaultID: cloudKitTestVaultID),
                        vaultID: cloudKitTestVaultID,
                        remoteKind: .iCloud,
                        remotePath: storeB.remotePath
                    )
                )
            )
        )

        // A changes and uploads revision 2; B edits on top of its stale baseline.
        let dataA = cloudKitTestVaultData("edit-a")
        let dataB = cloudKitTestVaultData("edit-b")
        let snapshotA = try cloudKitTestSnapshot(
            data: dataA,
            deviceID: "device-a",
            capturedAt: cloudKitTestReferenceDate.addingTimeInterval(300)
        )
        let snapshotB = try cloudKitTestSnapshot(
            data: dataB,
            deviceID: "device-b",
            capturedAt: cloudKitTestReferenceDate.addingTimeInterval(300)
        )
        let pushA = try #require(try await engineA.push(local: snapshotA, store: storeA, record: pushBase.record))
        #expect(pushA.receipt.manifestRevision == "2")

        let remote = try #require(try await storeB.readRemote())
        let decisionB = engineB.plan(local: snapshotB, record: baselineB, remote: remote)
        guard case .conflict(let conflict) = decisionB else {
            Issue.record("expected a conflict decision, got \(decisionB)")
            return
        }
        #expect(conflict.localChanged)
        #expect(conflict.remoteChanged)

        let error = await captureCloudVaultError {
            try await engineB.push(local: snapshotB, store: storeB, record: baselineB)
        }
        guard case .conflictRequiresResolution = error else {
            Issue.record("expected conflictRequiresResolution, got \(String(describing: error))")
            return
        }
        #expect(transport.storedData(recordName: pushA.receipt.fileName) == dataA)

        // The losing side is preserved as a separate encrypted copy, never merged.
        let copy = try await storeB.writeConflictCopy(
            vaultData: dataB,
            manifest: CloudVaultManifest.make(local: snapshotB, revision: 2),
            deviceName: cloudKitTestDeviceName,
            now: cloudKitTestReferenceDate
        )
        #expect(copy.fileName.hasPrefix(CloudKitVaultSpec.conflictCopyPrefix))
        #expect(transport.storedData(recordName: copy.fileName) == dataB)
        #expect(transport.storedData(recordName: pushA.receipt.fileName) == dataA)
    }
}
