import CryptoKit
import Foundation
import MonicaSync
import Network
import Observation
import Security

// MARK: - Errors

enum AppLanSyncError: Error, LocalizedError, Equatable {
    case identityUnavailable
    case stateUnavailable
    case keychain(OSStatus)
    case handshakeFailed(String)
    case vaultMismatch
    case snapshotIntegrity
    case identityMismatch
    case peerReported(String)
    case vaultLocked

    var errorDescription: String? {
        switch self {
        case .identityUnavailable:
            "本机局域网同步身份不可用。请重新打开该页面，或在设置中重置局域网同步后重试。"
        case .stateUnavailable:
            "局域网同步状态未就绪，请重新打开该页面后重试。"
        case .keychain(let status):
            "无法访问钥匙串保存同步身份（错误码 \(status)）。请确认设备已解锁后重试。"
        case .handshakeFailed(let reason):
            "配对未完成：\(reason)"
        case .vaultMismatch:
            "两台设备打开的不是同一个保险库，无法直接同步。请确认双方都解锁了同一个保险库后再试。"
        case .snapshotIntegrity:
            "对方发送的同步数据校验失败，已取消本次同步，本地数据没有被修改。"
        case .identityMismatch:
            "对方设备的身份与此前配对时不一致。这可能是设备重置，也可能有人试图冒充已配对设备。如果对方确实重置过设备，请先在对方设备上重新配对；否则请停止同步。"
        case .peerReported(let reason):
            "对方设备未能完成同步：\(reason)"
        case .vaultLocked:
            "保险库已锁定，无法继续局域网同步。请先解锁保险库。"
        }
    }
}

// MARK: - Bridge types

/// 一条可同步的本地条目。`localEntryID` 只在本机使用，永远不会发送到对端。
struct AppLanSyncEntryDraft {
    var localEntryID: String
    var projectTitle: String
    var title: String
    var favorite: Bool
    var content: LanSyncItemContent
    var kind: LanSyncItemKind

    func makeItem(syncID: UUID) -> LanSyncItem {
        LanSyncItem(
            syncID: syncID,
            projectTitle: projectTitle,
            title: title,
            favorite: favorite,
            content: content
        )
    }
}

/// 应用合并动作的结果。逐条失败通过 `failures` 返回，而不是整体抛错，
/// 这样已经成功的条目不会在下一次重试时被重复创建。
struct AppLanSyncApplyOutcome {
    var createdLocalEntryIDs: [UUID: String] = [:]
    var succeededSyncIDs: Set<UUID> = []
    var failures: [String] = []
}

/// App 会话与局域网同步协调器之间的桥。全部回调都在主线程执行。
struct AppLanSyncVaultBridge {
    var vaultID: String
    var localDeviceID: String
    var displayName: String
    var stateFileURL: URL
    var loadEntries: @MainActor () throws -> [AppLanSyncEntryDraft]
    var loadDeletedEntryIDs: @MainActor () throws -> [String]
    var apply: @MainActor ([LanSyncMergeAction], [UUID: String]) throws -> AppLanSyncApplyOutcome
    var refresh: @MainActor () throws -> Void
}

// MARK: - Device identity persistence

/// 本机同步身份（Ed25519 签名密钥 + X25519 协商密钥）保存在钥匙串里，
/// 和保险库解锁密钥分开存放。只在设备解锁后可读。
final class AppLanSyncIdentityStore {
    static let service = "com.monicapass.monica.lansync"
    static let account = "device-identity-v1"

    func loadOrCreate() throws -> LanSyncDeviceIdentity {
        if let material = try load() {
            do {
                return try LanSyncDeviceIdentity(privateMaterial: material)
            } catch {
                try reset()
                let identity = LanSyncDeviceIdentity()
                try save(identity.exportPrivateMaterial())
                return identity
            }
        }
        let identity = LanSyncDeviceIdentity()
        try save(identity.exportPrivateMaterial())
        return identity
    }

    func load() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppLanSyncError.keychain(status)
        }
        return data
    }

    func reset() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppLanSyncError.keychain(status)
        }
    }

    private func save(_ material: Data) throws {
        try reset()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: material,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AppLanSyncError.keychain(status)
        }
    }
}

// MARK: - Frame reader

/// 把连接上的帧流转成顺序读取器，避免把 AsyncStream 的迭代器到处传递。
/// 只在协调器的主线程路径上顺序使用，因此标记为 `@unchecked Sendable`。
private final class AppLanSyncFrameReader: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<LanSyncFrame, Error>.Iterator

    init(_ stream: AsyncThrowingStream<LanSyncFrame, Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> LanSyncFrame {
        guard let frame = try await iterator.next() else {
            throw AppLanSyncNetworkError.frameStreamClosed
        }
        return frame
    }
}

// MARK: - Coordinator

/// 局域网同步的会话协调器：身份、握手、加密通道、快照合并与幂等重试都在这里编排。
///
/// 约束（对应 issue #53）：
/// - 只有用户点「发起同步」或「加入同步」后才会广播/浏览，离开页面即停止；
/// - Bonjour 广播不包含任何保险库数据，配对必须经过 6 位配对码和双端验证码确认；
/// - 合并失败只报告冲突，绝不覆盖本地已修改的数据，也绝不删除原保险库。
@MainActor
@Observable
final class AppLanSyncCoordinator {
    enum Stage: Equatable {
        case idle
        case hosting(code: String)
        case browsing
        case connecting(peerName: String)
        case verifying(peerName: String)
        case syncing(peerName: String)
        case finished
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .idle, .finished, .failed:
                false
            default:
                true
            }
        }
    }

    private static let verificationTimeout: TimeInterval = 90

    private let bridge: AppLanSyncVaultBridge
    private let identityStore: AppLanSyncIdentityStore

    private(set) var stage: Stage = .idle
    private(set) var peers: [AppLanSyncPeer] = []
    private(set) var verificationPrompt: LanSyncVerificationPrompt?
    private(set) var importedReceipt: LanSyncTransferReceipt?
    private(set) var peerReceipt: LanSyncTransferReceipt?
    private(set) var conflicts: [LanSyncMergeConflict] = []
    private(set) var pairedPeers: [LanSyncPeerRecord] = []
    private(set) var guidance: String?

    private var identity: LanSyncDeviceIdentity?
    private var syncState: LanSyncSyncState?
    private var listener: AppLanSyncListener?
    private var browser: AppLanSyncBrowser?
    private var activeConnection: AppLanSyncConnection?
    private var sessionTask: Task<Void, Never>?
    private var verificationContinuation: CheckedContinuation<Bool, Never>?
    private var verificationWatchdog: Task<Void, Never>?
    private var pendingHostSecret: LanSyncPairingSecret?
    private var hostFailureCount = 0
    private var cooldownUntil: Date?

    init(bridge: AppLanSyncVaultBridge, identityStore: AppLanSyncIdentityStore = AppLanSyncIdentityStore()) {
        self.bridge = bridge
        self.identityStore = identityStore
    }

    // MARK: Lifecycle

    /// 幂等：加载（或首次创建）本机身份与同步状态。页面出现时调用。
    func prepare() {
        if identity == nil {
            do {
                identity = try identityStore.loadOrCreate()
            } catch {
                stage = .failed(readable(error))
                return
            }
        }
        do {
            try loadSyncState()
        } catch {
            stage = .failed(readable(error))
            return
        }
        refreshPairedPeers()
    }

    func resetSyncState() {
        guard identity != nil else {
            stage = .failed(readable(AppLanSyncError.identityUnavailable))
            return
        }
        // 保留条目映射（本地 ID ↔ syncID），这样重置后重新配对仍能识别同一批条目，
        // 不会因为重新生成 syncID 而在对端重复创建。只清除配对关系、合并基线和重试账本。
        var fresh = LanSyncSyncState(localDeviceID: bridge.localDeviceID, localVaultID: bridge.vaultID)
        if let existing = syncState {
            fresh.mappings = existing.mappings
        }
        do {
            try LanSyncSyncStateCodec.save(fresh, to: bridge.stateFileURL)
            syncState = fresh
            pairedPeers = []
            conflicts = []
            importedReceipt = nil
            peerReceipt = nil
            stage = .idle
        } catch {
            stage = .failed(readable(error))
        }
    }

    /// 彻底停止广播、浏览和进行中的会话。页面消失或保险库锁定时调用。
    func cancel() {
        verificationWatchdog?.cancel()
        verificationWatchdog = nil
        verificationContinuation?.resume(returning: false)
        verificationContinuation = nil
        verificationPrompt = nil

        activeConnection?.cancel()
        activeConnection = nil
        sessionTask?.cancel()
        sessionTask = nil
        listener?.stop()
        listener = nil
        browser?.stop()
        browser = nil
        pendingHostSecret = nil

        if case .finished = stage {
            // 保留完成摘要，让用户看完再离开。
        } else {
            stage = .idle
        }
    }

    // MARK: Hosting

    func startHosting() {
        guard sessionTask == nil else { return }
        stopBrowsing()
        listener?.stop()
        listener = nil

        prepare()
        guard identity != nil, syncState != nil else { return }

        if let cooldownUntil, cooldownUntil > Date() {
            let remaining = max(1, Int(cooldownUntil.timeIntervalSinceNow.rounded(.up)))
            stage = .failed("配对失败次数过多，请等待 \(remaining) 秒后再试。")
            return
        }

        guard let identity else {
            stage = .failed(readable(AppLanSyncError.identityUnavailable))
            return
        }

        let secret = LanSyncPairingSecret.generateShortCode()
        pendingHostSecret = secret
        hostFailureCount = 0
        conflicts = []
        importedReceipt = nil
        peerReceipt = nil
        guidance = nil

        let listener = AppLanSyncListener(
            serviceName: bridge.displayName,
            deviceID: identity.deviceID,
            onReady: { _ in },
            onDenied: { [weak self] in
                Task { @MainActor in self?.handleLocalNetworkDenied() }
            },
            onFailed: { [weak self] message in
                Task { @MainActor in self?.handleNetworkFailure(message) }
            },
            onConnection: { [weak self] connection in
                Task { @MainActor in self?.handleIncomingConnection(connection) }
            }
        )
        self.listener = listener
        do {
            try listener.start()
            if case let .shortCode(code) = secret {
                stage = .hosting(code: code)
            } else {
                stage = .hosting(code: "")
            }
        } catch {
            self.listener = nil
            stage = .failed(readable(error))
        }
    }

    private func handleIncomingConnection(_ connection: AppLanSyncConnection) {
        guard sessionTask == nil, let secret = pendingHostSecret else {
            connection.cancel()
            return
        }
        activeConnection = connection
        stage = .connecting(peerName: "附近设备")
        sessionTask = Task { [weak self] in
            guard let self else { return }
            await self.runSession(
                role: .host,
                advertisedPeerID: nil,
                secret: secret,
                connection: connection
            )
        }
    }

    // MARK: Browsing / joining

    func startBrowsing() {
        guard sessionTask == nil else { return }
        listener?.stop()
        listener = nil
        stopBrowsing()
        prepare()
        guard identity != nil else { return }

        let browser = AppLanSyncBrowser(
            onResults: { [weak self] results in
                Task { @MainActor in self?.handleBrowseResults(results) }
            },
            onDenied: { [weak self] in
                Task { @MainActor in self?.handleLocalNetworkDenied() }
            },
            onFailed: { [weak self] message in
                Task { @MainActor in self?.handleNetworkFailure(message) }
            }
        )
        self.browser = browser
        peers = []
        guidance = nil
        stage = .browsing
        browser.start()
    }

    func stopBrowsing() {
        browser?.stop()
        browser = nil
        if case .browsing = stage {
            stage = .idle
        }
    }

    private func handleBrowseResults(_ results: [NWBrowser.Result]) {
        guard let identity else { return }
        var seen = Set<String>()
        var found: [AppLanSyncPeer] = []
        for result in results {
            guard let peer = AppLanSyncNetwork.peer(from: result) else { continue }
            guard !peer.deviceID.isEmpty, peer.deviceID != identity.deviceID else { continue }
            guard seen.insert(peer.deviceID).inserted else { continue }
            found.append(peer)
        }
        found.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        peers = found
    }

    func join(peer: AppLanSyncPeer, code: String) {
        guard sessionTask == nil else { return }
        guard LanSyncPairingSecret.validateShortCode(code) else {
            stage = .failed("请输入对方设备上显示的 6 位数字配对码。")
            return
        }
        stopBrowsing()
        prepare()
        guard identity != nil, syncState != nil else { return }

        conflicts = []
        importedReceipt = nil
        peerReceipt = nil
        guidance = nil

        let secret = LanSyncPairingSecret.shortCode(LanSyncPairingSecret.normalizedCode(code))
        let connection = AppLanSyncNetwork.makeConnection(to: peer.endpoint) { [weak self] in
            Task { @MainActor in self?.handleLocalNetworkDenied() }
        }
        activeConnection = connection
        stage = .connecting(peerName: peer.displayName)
        sessionTask = Task { [weak self] in
            guard let self else { return }
            await self.runSession(
                role: .guest,
                advertisedPeerID: peer.deviceID,
                secret: secret,
                connection: connection
            )
        }
    }

    // MARK: Verification

    func confirmVerification(matches: Bool) {
        guard let continuation = verificationContinuation else { return }
        verificationContinuation = nil
        verificationWatchdog?.cancel()
        verificationWatchdog = nil
        if !matches {
            stage = .failed("配对已中止：两台设备上显示的验证码不一致时不要确认。")
        }
        verificationPrompt = nil
        continuation.resume(returning: matches)
    }

    private func waitForUserVerification() async -> Bool {
        await withCheckedContinuation { continuation in
            verificationContinuation = continuation
            verificationWatchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.verificationTimeout))
                guard !Task.isCancelled else { return }
                self?.confirmVerification(matches: false)
            }
        }
    }

    // MARK: Session orchestration

    private func runSession(
        role: LanSyncRole,
        advertisedPeerID: String?,
        secret: LanSyncPairingSecret,
        connection: AppLanSyncConnection
    ) async {
        defer {
            sessionTask = nil
            activeConnection = nil
            verificationPrompt = nil
            verificationWatchdog?.cancel()
            verificationWatchdog = nil
        }

        do {
            guard let identity, let state = syncState else {
                throw AppLanSyncError.stateUnavailable
            }
            guard state.localVaultID == bridge.vaultID else {
                throw AppLanSyncError.stateUnavailable
            }

            try await connection.start(timeout: 15)
            let reader = AppLanSyncFrameReader(connection.frames())
            let keys = try await runHandshake(
                role: role,
                identity: identity,
                advertisedPeerID: advertisedPeerID,
                secret: secret,
                reader: reader,
                connection: connection
            )
            try await runTransfer(keys: keys, reader: reader, connection: connection)

            if role == .host {
                hostFailureCount = 0
                pendingHostSecret = nil
                listener?.stop()
                listener = nil
            }
            stage = .finished
        } catch {
            if Task.isCancelled {
                connection.cancel()
                return
            }
            let message = readable(error)
            if role == .host {
                hostFailureCount += 1
                if hostFailureCount >= LanSyncProtocolSpec.maxPairingFailureCount {
                    listener?.stop()
                    listener = nil
                    cooldownUntil = Date().addingTimeInterval(LanSyncProtocolSpec.pairingFailureCooldown)
                    stage = .failed("配对连续失败 \(hostFailureCount) 次，已暂停广播。请核对配对码，\(Int(LanSyncProtocolSpec.pairingFailureCooldown)) 秒后重试。")
                } else {
                    stage = .failed(message)
                }
            } else {
                stage = .failed(message)
            }
        }
        connection.cancel()
    }

    private func runHandshake(
        role: LanSyncRole,
        identity: LanSyncDeviceIdentity,
        advertisedPeerID: String?,
        secret: LanSyncPairingSecret,
        reader: AppLanSyncFrameReader,
        connection: AppLanSyncConnection
    ) async throws -> LanSyncSessionKeys {
        let expectedPeer: LanSyncExpectedPeer? = {
            guard let advertisedPeerID, !advertisedPeerID.isEmpty, let state = syncState else {
                return nil
            }
            return state.expectedPeer(for: advertisedPeerID)
        }()

        let handshake = LanSyncHandshake(
            role: role,
            identity: identity,
            displayName: bridge.displayName,
            pairingSecret: secret,
            expectedPeer: expectedPeer
        )

        var outcome = try handshake.begin()
        try await send(outcome.outgoingFrames, on: connection)

        while true {
            try Task.checkCancellation()
            switch outcome.state {
            case .established:
                guard let keys = outcome.session else {
                    throw AppLanSyncError.handshakeFailed("会话密钥缺失")
                }
                try verifyPeerIdentity(keys, advertisedPeerID: advertisedPeerID)
                return keys
            case .failed(let failure):
                throw failure
            case .awaitingUserVerification:
                guard let prompt = outcome.verificationPrompt else {
                    throw AppLanSyncError.handshakeFailed("缺少验证码")
                }
                verificationPrompt = prompt
                stage = .verifying(peerName: prompt.peerDisplayName)
                let accepted = await waitForUserVerification()
                outcome = handshake.confirmUserVerification(matches: accepted)
                try await send(outcome.outgoingFrames, on: connection)
                if let failure = outcome.failure {
                    throw failure
                }
            default:
                let frame = try await reader.next()
                outcome = try handshake.receive(frame)
                if let failure = outcome.failure {
                    throw failure
                }
                try await send(outcome.outgoingFrames, on: connection)
            }
        }
    }

    private func verifyPeerIdentity(_ keys: LanSyncSessionKeys, advertisedPeerID: String?) throws {
        if let advertisedPeerID, !advertisedPeerID.isEmpty, advertisedPeerID != keys.peerDeviceID {
            throw AppLanSyncError.identityMismatch
        }
        if let pinned = syncState?.peer(keys.peerDeviceID) {
            guard pinned.signingPublicKey == keys.peerSigningPublicKey else {
                throw AppLanSyncError.identityMismatch
            }
        }
    }

    // MARK: Transfer

    private func runTransfer(
        keys: LanSyncSessionKeys,
        reader: AppLanSyncFrameReader,
        connection: AppLanSyncConnection
    ) async throws {
        stage = .syncing(peerName: keys.peerDisplayName)
        let channel = keys.makeSecureChannel()

        let snapshot = try buildLocalSnapshot(peerDeviceID: keys.peerDeviceID)
        try saveSyncState()

        let snapshotFrame = try channel.seal(
            LanSyncSecureMessage(kind: .snapshot, payload: try JSONEncoder().encode(snapshot))
        )
        try await connection.send(snapshotFrame)

        var remoteReceiptReceived = false
        var receiptSent = false

        while !(remoteReceiptReceived && receiptSent) {
            let incoming = try await reader.next()
            let message = try channel.open(incoming)
            switch message.kind {
            case .snapshot:
                let remote = try JSONDecoder().decode(LanSyncVaultSnapshot.self, from: message.payload)
                do {
                    let receipt = try applyRemoteSnapshot(remote, keys: keys)
                    importedReceipt = receipt
                    let reply = try channel.seal(
                        LanSyncSecureMessage(kind: .receipt, payload: try JSONEncoder().encode(receipt))
                    )
                    try await connection.send(reply)
                    receiptSent = true
                } catch {
                    await sendSecureError(readable(error), channel: channel, connection: connection)
                    throw error
                }
            case .receipt:
                let receipt = try JSONDecoder().decode(LanSyncTransferReceipt.self, from: message.payload)
                guard receipt.receiverDeviceID == bridge.localDeviceID else { continue }
                peerReceipt = receipt
                remoteReceiptReceived = true
            case .syncComplete:
                break
            case .error:
                let detail = String(data: message.payload, encoding: .utf8) ?? "未提供原因"
                throw AppLanSyncError.peerReported(detail)
            }
        }
    }

    private func buildLocalSnapshot(peerDeviceID: String) throws -> LanSyncVaultSnapshot {
        guard syncState != nil else { throw AppLanSyncError.stateUnavailable }
        let drafts = try bridge.loadEntries()
        var items: [LanSyncItem] = []
        for draft in drafts {
            let syncID: UUID
            if let mapping = syncState?.mapping(forLocalEntryID: draft.localEntryID) {
                syncID = mapping.syncID
            } else {
                syncID = UUID()
            }
            let item = draft.makeItem(syncID: syncID)
            items.append(item)
            syncState?.setMapping(
                LanSyncEntryMapping(
                    localEntryID: draft.localEntryID,
                    syncID: syncID,
                    kind: draft.kind,
                    lastKnownContentHash: item.contentHash
                )
            )
        }

        let deletedIDs = Set(try bridge.loadDeletedEntryIDs())
        let tombstones = localTombstones(deletedEntryIDs: deletedIDs, base: syncState?.base(forPeer: peerDeviceID))

        let revision = Int((syncState?.base(forPeer: peerDeviceID)?.lastSyncedAt.timeIntervalSince1970 ?? 0).rounded())
        return try LanSyncVaultSnapshot.make(
            vaultID: bridge.vaultID,
            senderDeviceID: bridge.localDeviceID,
            senderDisplayName: bridge.displayName,
            revision: revision,
            items: items,
            tombstones: tombstones
        )
    }

    private func localTombstones(deletedEntryIDs: Set<String>, base: LanSyncMergeBase?) -> [LanSyncTombstone] {
        guard let mappings = syncState?.mappings.values else { return [] }
        var tombstones: [LanSyncTombstone] = []
        for mapping in mappings where deletedEntryIDs.contains(mapping.localEntryID) {
            let hash = mapping.lastKnownContentHash ?? base?.item(for: mapping.syncID)?.contentHash
            tombstones.append(
                LanSyncTombstone(syncID: mapping.syncID, deletedAt: Date(), deletedContentHash: hash)
            )
        }
        return tombstones
    }

    private func applyRemoteSnapshot(
        _ snapshot: LanSyncVaultSnapshot,
        keys: LanSyncSessionKeys
    ) throws -> LanSyncTransferReceipt {
        guard let state = syncState else { throw AppLanSyncError.stateUnavailable }
        do {
            try snapshot.verifyIntegrity()
        } catch {
            throw AppLanSyncError.snapshotIntegrity
        }
        guard snapshot.vaultID == bridge.vaultID else {
            throw AppLanSyncError.vaultMismatch
        }

        let content = Self.contentIdentity(snapshot)
        if let previous = state.ledger.previousApplication(
            transferID: content.transferID,
            digest: content.digest
        ) {
            // 连接中断后重试：这一份数据已经应用过，直接返回原回执，
            // 保证「重试幂等」，不会重复创建条目。
            return previous.receipt(alreadyApplied: true)
        }

        let base = state.base(forPeer: snapshot.senderDeviceID)
        let drafts = try bridge.loadEntries()
        var localItems: [LanSyncLocalItem] = []
        for draft in drafts {
            let syncID: UUID
            if let mapping = syncState?.mapping(forLocalEntryID: draft.localEntryID) {
                syncID = mapping.syncID
            } else {
                syncID = UUID()
                syncState?.setMapping(
                    LanSyncEntryMapping(
                        localEntryID: draft.localEntryID,
                        syncID: syncID,
                        kind: draft.kind,
                        lastKnownContentHash: nil
                    )
                )
            }
            let item = draft.makeItem(syncID: syncID)
            localItems.append(LanSyncLocalItem(item: item, localEntryID: draft.localEntryID))
            syncState?.setMapping(
                LanSyncEntryMapping(
                    localEntryID: draft.localEntryID,
                    syncID: syncID,
                    kind: draft.kind,
                    lastKnownContentHash: item.contentHash
                )
            )
        }

        let deletedIDs = Set(try bridge.loadDeletedEntryIDs())
        let tombstones = localTombstones(deletedEntryIDs: deletedIDs, base: base)

        let result = LanSyncMergeEngine().merge(
            remote: snapshot,
            localItems: localItems,
            localTombstones: tombstones,
            base: base
        )

        var existingMappings: [UUID: String] = [:]
        if let mappings = syncState?.mappings.values {
            for mapping in mappings {
                existingMappings[mapping.syncID] = mapping.localEntryID
            }
        }

        let outcome = try bridge.apply(result.actions, existingMappings)
        var newBase = result.base
        for action in result.actions {
            switch action {
            case .create(let item):
                if let localEntryID = outcome.createdLocalEntryIDs[item.syncID] {
                    newBase.setItem(
                        LanSyncMergeBaseItem(
                            contentHash: item.contentHash,
                            localEntryID: localEntryID,
                            kind: item.kind
                        ),
                        for: item.syncID
                    )
                    syncState?.setMapping(
                        LanSyncEntryMapping(
                            localEntryID: localEntryID,
                            syncID: item.syncID,
                            kind: item.kind,
                            lastKnownContentHash: item.contentHash
                        )
                    )
                } else {
                    // 创建失败：不要把它记入 merge base，下一次同步会重试。
                    newBase.removeRecord(for: item.syncID)
                }
            case .update(let item, let localEntryID):
                guard outcome.succeededSyncIDs.contains(item.syncID) else { continue }
                newBase.setItem(
                    LanSyncMergeBaseItem(
                        contentHash: item.contentHash,
                        localEntryID: localEntryID,
                        kind: item.kind
                    ),
                    for: item.syncID
                )
                syncState?.setMapping(
                    LanSyncEntryMapping(
                        localEntryID: localEntryID,
                        syncID: item.syncID,
                        kind: item.kind,
                        lastKnownContentHash: item.contentHash
                    )
                )
            case .delete(let syncID, let localEntryID):
                guard outcome.succeededSyncIDs.contains(syncID) else { continue }
                let hash = base?.item(for: syncID)?.contentHash
                    ?? syncState?.mapping(forSyncID: syncID)?.lastKnownContentHash
                newBase.setTombstone(
                    LanSyncMergeBaseTombstone(deletedAt: Date(), lastContentHash: hash),
                    for: syncID
                )
                syncState?.removeMapping(forLocalEntryID: localEntryID)
            }
        }

        syncState?.setBase(newBase, forPeer: snapshot.senderDeviceID)
        syncState?.upsertPeer(
            LanSyncPeerRecord(
                deviceID: snapshot.senderDeviceID,
                displayName: snapshot.senderDisplayName,
                signingPublicKey: keys.peerSigningPublicKey,
                lastSyncedAt: Date(),
                lastSessionFingerprint: keys.sessionFingerprint
            )
        )
        let record = LanSyncTransferRecord(
            transferID: content.transferID,
            snapshotDigest: content.digest,
            receiverDeviceID: bridge.localDeviceID,
            summary: result.summary
        )
        syncState?.ledger.remember(record)

        try saveSyncState()
        do {
            try bridge.refresh()
        } catch {
            // 刷新界面失败不影响合并结果的持久化，下一次刷新会补上。
        }
        conflicts = result.conflicts
        refreshPairedPeers()
        return record.receipt(alreadyApplied: false)
    }

    private func sendSecureError(
        _ message: String,
        channel: LanSyncSecureChannel,
        connection: AppLanSyncConnection
    ) async {
        guard let frame = try? channel.seal(
            LanSyncSecureMessage(kind: .error, payload: Data(message.utf8))
        ) else {
            return
        }
        try? await connection.send(frame)
    }

    private func send(_ frames: [LanSyncFrame], on connection: AppLanSyncConnection) async throws {
        for frame in frames {
            try await connection.send(frame)
        }
    }

    // MARK: State helpers

    private func loadSyncState() throws {
        if let loaded = try LanSyncSyncStateCodec.load(from: bridge.stateFileURL),
           loaded.localVaultID == bridge.vaultID {
            syncState = loaded
            return
        }
        let fresh = LanSyncSyncState(localDeviceID: bridge.localDeviceID, localVaultID: bridge.vaultID)
        try LanSyncSyncStateCodec.save(fresh, to: bridge.stateFileURL)
        syncState = fresh
    }

    private func saveSyncState() throws {
        guard var state = syncState else { throw AppLanSyncError.stateUnavailable }
        state.updatedAt = Date()
        try LanSyncSyncStateCodec.save(state, to: bridge.stateFileURL)
    }

    private func refreshPairedPeers() {
        let records = syncState?.peers.values.map { $0 } ?? []
        pairedPeers = records.sorted { lhs, rhs in
            (lhs.lastSyncedAt ?? lhs.firstPairedAt) > (rhs.lastSyncedAt ?? rhs.firstPairedAt)
        }
    }

    // MARK: Network failure handling

    private func handleLocalNetworkDenied() {
        guidance = AppLanSyncNetworkError.localNetworkDenied.localizedDescription
        teardownNetworking()
        sessionTask?.cancel()
        sessionTask = nil
        stage = .failed(
            AppLanSyncNetworkError.localNetworkDenied.localizedDescription
        )
    }

    private func handleNetworkFailure(_ message: String) {
        guard sessionTask == nil else { return }
        teardownNetworking()
        stage = .failed(message)
    }

    private func teardownNetworking() {
        activeConnection?.cancel()
        activeConnection = nil
        listener?.stop()
        listener = nil
        browser?.stop()
        browser = nil
        pendingHostSecret = nil
    }

    private func readable(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    // MARK: Content identity (idempotency key)

    private struct SnapshotContentIdentity {
        var transferID: String
        var digest: Data
    }

    /// 只根据内容计算幂等键，不包含 `exportedAt`/`revision` 等每次都会变化的字段。
    /// 这样断线重连后重新发送同一份数据时，接收端能识别出「已经应用过」。
    private static func contentIdentity(_ snapshot: LanSyncVaultSnapshot) -> SnapshotContentIdentity {
        var hasher = SHA256()
        for item in snapshot.items.sorted(by: { $0.syncID.uuidString < $1.syncID.uuidString }) {
            hasher.update(data: Data(item.syncID.uuidString.utf8))
            hasher.update(data: Data([0x00]))
            hasher.update(data: item.contentHash)
            hasher.update(data: Data([0x00]))
        }
        for tombstone in snapshot.tombstones.sorted(by: { $0.syncID.uuidString < $1.syncID.uuidString }) {
            hasher.update(data: Data(tombstone.syncID.uuidString.utf8))
            hasher.update(data: Data([0xFF]))
            hasher.update(data: tombstone.deletedContentHash ?? Data())
            hasher.update(data: Data([0xFF]))
        }
        let digest = Data(hasher.finalize())
        return SnapshotContentIdentity(
            transferID: "ls-" + LanSyncEncoding.hex(digest.prefix(16)),
            digest: digest
        )
    }
}
