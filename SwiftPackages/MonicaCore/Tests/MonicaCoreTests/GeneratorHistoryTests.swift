import Foundation
import Testing
import MonicaCore

private actor RecordingHistoryStore: GeneratorHistoryPersisting {
    private var payloads: [String: Data] = [:]
    private(set) var saveCount = 0
    private(set) var loadCount = 0
    private(set) var removeCount = 0

    func load(vaultID: String) async throws -> Data? {
        loadCount += 1
        return payloads[vaultID]
    }

    func save(_ payload: Data, vaultID: String) async throws {
        saveCount += 1
        payloads[vaultID] = payload
    }

    func remove(vaultID: String) async throws {
        removeCount += 1
        payloads[vaultID] = nil
    }

    func payload(for vaultID: String) -> Data? {
        payloads[vaultID]
    }
}

private let historyStart = Date(timeIntervalSince1970: 1_800_000_000)

private func historyKey(_ byte: UInt8 = 0x42) -> Data {
    Data(repeating: byte, count: GeneratorHistoryKeyMaterial.requiredByteCount)
}

// MARK: - 密文

@Test func historyCipherRoundTripsAndRejectsTampering() throws {
    let cipher = GeneratorHistoryCipher()
    let key = historyKey()
    let context = Data("monica.test".utf8)
    let entries = [
        GeneratorHistoryEntry(
            kind: .password,
            value: "Amber-Harbor-42!",
            createdAt: historyStart,
            expiresAt: historyStart.addingTimeInterval(3600)
        ),
    ]

    let payload = try cipher.seal(entries: entries, keyMaterial: key, context: context, savedAt: historyStart)
    // 密文里不出现明文，避免普通持久化直接读到历史内容。
    #expect(!String(decoding: payload, as: UTF8.self).contains("Amber-Harbor-42!"))
    #expect(try cipher.open(payload, keyMaterial: key, context: context).entries == entries)

    var tampered = payload
    tampered[tampered.count - 1] ^= 0xFF
    #expect(throws: GeneratorHistoryError.corruptedPayload) {
        try cipher.open(tampered, keyMaterial: key, context: context)
    }

    #expect(throws: GeneratorHistoryError.corruptedPayload) {
        try cipher.open(payload, keyMaterial: historyKey(0x43), context: context)
    }

    #expect(throws: GeneratorHistoryError.corruptedPayload) {
        try cipher.open(payload, keyMaterial: key, context: Data("other".utf8))
    }

    #expect(throws: GeneratorHistoryError.invalidKeyMaterial) {
        try cipher.seal(
            entries: entries,
            keyMaterial: Data(repeating: 0, count: 31),
            context: context,
            savedAt: historyStart
        )
    }
}

@Test func historyKeyMaterialIsCryptographicallyRandom() throws {
    let first = try GeneratorHistoryKeyMaterial.random()
    let second = try GeneratorHistoryKeyMaterial.random()

    #expect(first.count == GeneratorHistoryKeyMaterial.requiredByteCount)
    #expect(second.count == GeneratorHistoryKeyMaterial.requiredByteCount)
    #expect(first != second)
}

// MARK: - Vault 门禁

@Test func historyVaultRejectsAccessWhileLocked() async throws {
    let vault = GeneratorHistoryVault(store: RecordingHistoryStore())

    await #expect(throws: GeneratorHistoryError.vaultLocked) {
        try await vault.entries()
    }
    await #expect(throws: GeneratorHistoryError.vaultLocked) {
        try await vault.record(kind: .password, value: "x")
    }
    await #expect(throws: GeneratorHistoryError.vaultLocked) {
        try await vault.clear()
    }
    let isUnlocked = await vault.isUnlocked
    #expect(!isUnlocked)

    await #expect(throws: GeneratorHistoryError.invalidVaultIdentifier) {
        try await vault.unlock(vaultID: "   ", keyMaterial: historyKey())
    }
    await #expect(throws: GeneratorHistoryError.invalidKeyMaterial) {
        try await vault.unlock(vaultID: "vault-alpha", keyMaterial: Data(repeating: 1, count: 8))
    }
}

@Test func historyVaultPersistsCiphertextAcrossReopen() async throws {
    let store = RecordingHistoryStore()
    let key = historyKey(0x11)
    let vault = GeneratorHistoryVault(store: store)
    try await vault.unlock(vaultID: "vault-alpha", keyMaterial: key)
    let recorded = try await vault.record(
        kind: .password,
        value: "Amber-Harbor-42!",
        at: historyStart,
        retention: .never
    )
    #expect(recorded.count == 1)

    let payload = try #require(await store.payload(for: "vault-alpha"))
    #expect(!String(decoding: payload, as: UTF8.self).contains("Amber-Harbor-42!"))

    // 新建实例模拟 App 重启：同一密钥解锁后历史仍可见。
    let reopened = GeneratorHistoryVault(store: store)
    try await reopened.unlock(vaultID: "vault-alpha", keyMaterial: key)
    let entries = try await reopened.entries(
        at: historyStart.addingTimeInterval(60),
        retention: .never
    )
    #expect(entries.count == 1)
    #expect(entries.first?.value == "Amber-Harbor-42!")
    #expect(entries.first?.kind == .password)
}

@Test func historyVaultPrunesExpiredEntriesAndCapsCount() async throws {
    let store = RecordingHistoryStore()
    let vault = GeneratorHistoryVault(store: store)
    try await vault.unlock(vaultID: "vault-alpha", keyMaterial: historyKey(0x22))

    _ = try await vault.record(kind: .password, value: "one", at: historyStart, retention: .oneHour)
    let later = historyStart.addingTimeInterval(2 * 60 * 60)
    let expired = try await vault.entries(at: later, retention: .oneHour)
    #expect(expired.isEmpty)
    // 过期清理必须回写，否则密文里会长期保留已过期的历史。
    let savesAfterPrune = await store.saveCount
    #expect(savesAfterPrune >= 2)

    for index in 0..<25 {
        _ = try await vault.record(
            kind: .pin,
            value: "pin-\(index)",
            at: historyStart,
            retention: .oneHour
        )
    }
    let capped = try await vault.entries(at: historyStart, retention: .oneHour)
    #expect(capped.count == GeneratorHistoryRetention.oneHour.maximumEntryCount)
    #expect(capped.first?.value == "pin-24")
}

@Test func historyVaultLockWipesKeyAndBlocksReads() async throws {
    let store = RecordingHistoryStore()
    let key = historyKey(0x33)
    let vault = GeneratorHistoryVault(store: store)
    try await vault.unlock(vaultID: "vault-alpha", keyMaterial: key)
    _ = try await vault.record(kind: .apiToken, value: "monica_abc", at: historyStart, retention: .oneDay)

    await vault.lock()
    let isUnlocked = await vault.isUnlocked
    #expect(!isUnlocked)
    await #expect(throws: GeneratorHistoryError.vaultLocked) {
        try await vault.entries(at: historyStart, retention: .oneDay)
    }

    // 锁库只影响访问：密文仍在，用同一密钥重新解锁后恢复可读。
    try await vault.unlock(vaultID: "vault-alpha", keyMaterial: key)
    let entries = try await vault.entries(at: historyStart, retention: .oneDay)
    #expect(entries.map(\.value) == ["monica_abc"])
}

@Test func historyVaultClearDeletesPersistedData() async throws {
    let store = RecordingHistoryStore()
    let vault = GeneratorHistoryVault(store: store)
    try await vault.unlock(vaultID: "vault-alpha", keyMaterial: historyKey(0x44))
    _ = try await vault.record(kind: .username, value: "Amber_Anchor_42", at: historyStart, retention: .never)
    #expect(await store.payload(for: "vault-alpha") != nil)

    try await vault.clear()
    let remaining = await store.payload(for: "vault-alpha")
    #expect(remaining == nil)
    let entries = try await vault.entries(at: historyStart, retention: .never)
    #expect(entries.isEmpty)
}

// MARK: - 开关行为

@Test func coordinatorKeepsHistoryInMemoryWhenDisabled() async throws {
    let store = RecordingHistoryStore()
    let coordinator = GeneratorHistoryCoordinator(
        vault: GeneratorHistoryVault(store: store),
        policy: GeneratorHistoryPolicy(isEnabled: false, retention: .oneHour)
    )

    _ = try await coordinator.record(kind: .password, value: "memory-only", at: historyStart)
    _ = try await coordinator.record(kind: .pin, value: "482913", at: historyStart)

    let entries = try await coordinator.entries(at: historyStart)
    #expect(entries.map(\.value) == ["482913", "memory-only"])
    let saves = await store.saveCount
    #expect(saves == 0)
    let payload = await store.payload(for: "vault-alpha")
    #expect(payload == nil)

    // 离开页面 / 锁库后内存历史一并清空，不存在任何持久化副本。
    await coordinator.lock()
    let afterLock = try await coordinator.entries(at: historyStart)
    #expect(afterLock.isEmpty)
}

@Test func coordinatorRequiresUnlockedVaultWhenHistoryEnabled() async throws {
    let coordinator = GeneratorHistoryCoordinator(
        vault: GeneratorHistoryVault(store: RecordingHistoryStore()),
        policy: GeneratorHistoryPolicy(isEnabled: true, retention: .oneDay)
    )

    await #expect(throws: GeneratorHistoryError.vaultLocked) {
        try await coordinator.record(kind: .password, value: "x", at: historyStart)
    }
    await #expect(throws: GeneratorHistoryError.vaultLocked) {
        try await coordinator.entries(at: historyStart)
    }
}

@Test func coordinatorDisablingHistoryDeletesPersistedCiphertext() async throws {
    let store = RecordingHistoryStore()
    let coordinator = GeneratorHistoryCoordinator(
        vault: GeneratorHistoryVault(store: store),
        policy: GeneratorHistoryPolicy(isEnabled: true, retention: .never)
    )
    try await coordinator.unlock(vaultID: "vault-alpha", keyMaterial: historyKey(0x55))
    _ = try await coordinator.record(kind: .password, value: "secret", at: historyStart)
    #expect(await store.payload(for: "vault-alpha") != nil)

    try await coordinator.updatePolicy(GeneratorHistoryPolicy(isEnabled: false, retention: .never))
    let remaining = await store.payload(for: "vault-alpha")
    #expect(remaining == nil)

    let savesBefore = await store.saveCount
    _ = try await coordinator.record(kind: .password, value: "secret-2", at: historyStart)
    let savesAfter = await store.saveCount
    #expect(savesAfter == savesBefore)

    let entries = try await coordinator.entries(at: historyStart)
    #expect(entries.map(\.value) == ["secret-2"])
}

@Test func coordinatorExpiresMemoryHistoryByRetention() async throws {
    let coordinator = GeneratorHistoryCoordinator(
        vault: GeneratorHistoryVault(store: RecordingHistoryStore()),
        policy: GeneratorHistoryPolicy(isEnabled: false, retention: .oneHour)
    )

    _ = try await coordinator.record(kind: .password, value: "short-lived", at: historyStart)
    let fresh = try await coordinator.entries(at: historyStart.addingTimeInterval(60))
    #expect(fresh.count == 1)

    let expired = try await coordinator.entries(at: historyStart.addingTimeInterval(2 * 60 * 60))
    #expect(expired.isEmpty)
}

// MARK: - 文件存储

@Test func fileHistoryStoreSeparatesVaultsAndHidesIdentifiers() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("monica-generator-history-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = FileGeneratorHistoryStore(directoryURL: directory)
    let payload = Data([0x01, 0x02, 0x03])
    try await store.save(payload, vaultID: "vault-alpha")

    let alphaURL = try store.fileURL(for: "vault-alpha")
    let betaURL = try store.fileURL(for: "vault-beta")
    #expect(!alphaURL.lastPathComponent.contains("vault-alpha"))
    #expect(alphaURL != betaURL)

    let alphaPayload = try await store.load(vaultID: "vault-alpha")
    #expect(alphaPayload == payload)
    let betaPayload = try await store.load(vaultID: "vault-beta")
    #expect(betaPayload == nil)

    try await store.remove(vaultID: "vault-alpha")
    let removed = try await store.load(vaultID: "vault-alpha")
    #expect(removed == nil)

    #expect(throws: GeneratorHistoryError.invalidVaultIdentifier) {
        try store.fileURL(for: "  ")
    }
}
