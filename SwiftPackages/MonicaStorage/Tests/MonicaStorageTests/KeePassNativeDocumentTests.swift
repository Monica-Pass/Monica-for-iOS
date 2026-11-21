import Foundation
import Testing
@testable import MonicaStorage

// MARK: - Fixtures

private let fixturePassword = "native-manager-password"

private func kdbx4Inputs() -> KeePassKdbxPayloadCryptoInputs {
    KeePassKdbxPayloadCryptoInputs(
        masterSeed: Data(repeating: 0xA1, count: 32),
        encryptionIV: Data(repeating: 0xA2, count: 16),
        innerRandomStreamKey: Data(repeating: 0xA3, count: 32),
        streamStartBytes: nil,
        innerRandomStreamID: 2
    )
}

private func kdbx3Inputs() -> KeePassKdbxPayloadCryptoInputs {
    KeePassKdbxPayloadCryptoInputs(
        masterSeed: Data(repeating: 0xB1, count: 32),
        encryptionIV: Data(repeating: 0xB2, count: 16),
        innerRandomStreamKey: Data(repeating: 0xB3, count: 32),
        streamStartBytes: Data(repeating: 0xB4, count: 32),
        innerRandomStreamID: 2
    )
}

private func kdbx4KdfParameters() -> KeePassKdbxKdfParameters {
    KeePassKdbxKdfParameters(
        algorithm: .argon2id,
        argon2: KeePassKdbxArgon2Parameters(
            salt: Data(repeating: 0xA4, count: 32),
            iterations: 1,
            memoryBytes: 8 * 1024,
            parallelism: 1,
            version: 0x13
        )
    )
}

private func kdbx3KdfParameters() -> KeePassKdbxKdfParameters {
    KeePassKdbxKdfParameters(
        algorithm: .aesKdf,
        aesKdf: KeePassKdbxAesKdfParameters(
            seed: Data(repeating: 0xB5, count: 32),
            rounds: 1_000
        )
    )
}

private func base64UUID(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
}

private let rootGroupUUID = base64UUID(Array(repeating: 0x10, count: 16))
private let teamGroupUUID = base64UUID(Array(repeating: 0x11, count: 16))
private let mailEntryUUID = base64UUID(Array(repeating: 0x12, count: 16))
private let teamEntryUUID = base64UUID(Array(repeating: 0x13, count: 16))

private func makeFixtureXML(
    cryptoInputs: KeePassKdbxPayloadCryptoInputs,
    password: String = "s3cret-mail-password"
) throws -> Data {
    guard let encoder = try KeePassProtectedValueStreamEncoder.make(from: cryptoInputs) else {
        throw KeePassOperationError(
            code: .formatUnsupported,
            message: "fixture 缺少 inner stream 参数"
        )
    }
    let protectedPassword = encoder.encode(password)
    let protectedHistoryPassword = encoder.encode("old-history-secret")
    let stamp = KeePassNativeFixtureStamps.creation

    let xml = """
    <?xml version="1.0" encoding="utf-8" standalone="yes"?>
    <KeePassFile>
    \t<Meta>
    \t\t<Generator>KeePassXC</Generator>
    \t\t<DatabaseName>Native Fixture</DatabaseName>
    \t\t<RecycleBinUUID>\(teamGroupUUID)</RecycleBinUUID>
    \t\t<CustomVendorData>keep-me</CustomVendorData>
    \t\t<MemoryProtection>
    \t\t\t<ProtectTitle>False</ProtectTitle>
    \t\t\t<ProtectPassword>True</ProtectPassword>
    \t\t</MemoryProtection>
    \t</Meta>
    \t<Root>
    \t\t<Group>
    \t\t\t<UUID>\(rootGroupUUID)</UUID>
    \t\t\t<Name>Root</Name>
    \t\t\t<Notes>root group notes</Notes>
    \t\t\t<IconID>48</IconID>
    \t\t\t<Times>
    \t\t\t\t<CreationTime>\(stamp)</CreationTime>
    \t\t\t\t<LastModificationTime>\(stamp)</LastModificationTime>
    \t\t\t</Times>
    \t\t\t<Entry>
    \t\t\t\t<UUID>\(mailEntryUUID)</UUID>
    \t\t\t\t<IconID>0</IconID>
    \t\t\t\t<Times>
    \t\t\t\t\t<CreationTime>\(stamp)</CreationTime>
    \t\t\t\t\t<LastModificationTime>\(stamp)</LastModificationTime>
    \t\t\t\t</Times>
    \t\t\t\t<String>
    \t\t\t\t\t<Key>Title</Key>
    \t\t\t\t\t<Value>Mail</Value>
    \t\t\t\t</String>
    \t\t\t\t<String>
    \t\t\t\t\t<Key>UserName</Key>
    \t\t\t\t\t<Value>me@example.com</Value>
    \t\t\t\t</String>
    \t\t\t\t<String>
    \t\t\t\t\t<Key>Password</Key>
    \t\t\t\t\t<Value Protected="True">\(protectedPassword)</Value>
    \t\t\t\t</String>
    \t\t\t\t<String>
    \t\t\t\t\t<Key>URL</Key>
    \t\t\t\t\t<Value>https://mail.example.com</Value>
    \t\t\t\t</String>
    \t\t\t\t<String>
    \t\t\t\t\t<Key>Notes</Key>
    \t\t\t\t\t<Value>mail notes</Value>
    \t\t\t\t</String>
    \t\t\t\t<AutoType>
    \t\t\t\t\t<Enabled>True</Enabled>
    \t\t\t\t\t<DefaultSequence>{USERNAME}{TAB}{PASSWORD}{ENTER}</DefaultSequence>
    \t\t\t\t</AutoType>
    \t\t\t\t<CustomVendorEntry>keep-entry</CustomVendorEntry>
    \t\t\t\t<History>
    \t\t\t\t\t<Entry>
    \t\t\t\t\t\t<String>
    \t\t\t\t\t\t\t<Key>Password</Key>
    \t\t\t\t\t\t\t<Value Protected="True">\(protectedHistoryPassword)</Value>
    \t\t\t\t\t\t</String>
    \t\t\t\t\t</Entry>
    \t\t\t\t</History>
    \t\t\t</Entry>
    \t\t\t<Group>
    \t\t\t\t<UUID>\(teamGroupUUID)</UUID>
    \t\t\t\t<Name>Team</Name>
    \t\t\t\t<Notes>team notes</Notes>
    \t\t\t\t<IsExpanded>True</IsExpanded>
    \t\t\t\t<Entry>
    \t\t\t\t\t<UUID>\(teamEntryUUID)</UUID>
    \t\t\t\t\t<String>
    \t\t\t\t\t\t<Key>Title</Key>
    \t\t\t\t\t\t<Value>Deploy</Value>
    \t\t\t\t\t</String>
    \t\t\t\t\t<String>
    \t\t\t\t\t\t<Key>UserName</Key>
    \t\t\t\t\t\t<Value>ops</Value>
    \t\t\t\t\t</String>
    \t\t\t\t\t<String>
    \t\t\t\t\t\t<Key>URL</Key>
    \t\t\t\t\t\t<Value>ssh://deploy.example.com</Value>
    \t\t\t\t\t</String>
    \t\t\t\t\t<String>
    \t\t\t\t\t\t<Key>Notes</Key>
    \t\t\t\t\t\t<Value>ops entry</Value>
    \t\t\t\t\t</String>
    \t\t\t\t</Entry>
    \t\t\t</Group>
    \t\t</Group>
    \t\t<DeletedObjects />
    \t</Root>
    </KeePassFile>

    """
    guard let data = xml.data(using: .utf8) else {
        throw KeePassOperationError(code: .formatUnsupported, message: "fixture XML 编码失败")
    }
    return data
}

private enum KeePassNativeFixtureStamps {
    /// 2024-01-01 00:00:00 UTC 的 .NET 时间戳位模式（仅为固定值，测试不依赖具体时间）。
    static let creation = KeePassNativeTimestampForTests.base64(secondsSinceUnixEpoch: 1_704_067_200)
}

private enum KeePassNativeTimestampForTests {
    static func base64(secondsSinceUnixEpoch: Int64) -> String {
        let seconds = secondsSinceUnixEpoch + 62_135_596_800
        var littleEndian = seconds.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }.base64EncodedString()
    }
}

private func makeDatabase(container: KeePassNativeContainer) throws -> Data {
    let inputs = container == .kdbx4 ? kdbx4Inputs() : kdbx3Inputs()
    let xml = try makeFixtureXML(cryptoInputs: inputs)
    return try KeePassNativeKdbxWriter().writeDatabase(
        xmlData: xml,
        container: container,
        cipher: .aes256,
        compression: .gzip,
        kdfParameters: container == .kdbx4 ? kdbx4KdfParameters() : kdbx3KdfParameters(),
        credentials: KeePassUnlockCredentials(
            password: fixturePassword,
            keyFile: nil,
            keyFileName: nil
        ),
        cryptoInputs: inputs
    )
}

private func loadFixture(container: KeePassNativeContainer) throws -> KeePassNativeDocument {
    let database = try makeDatabase(container: container)
    return try KeePassNativeDocument.load(
        data: database,
        sourceName: container == .kdbx4 ? "fixture.kdbx" : "fixture-v3.kdbx",
        credentials: KeePassUnlockCredentials(
            password: fixturePassword,
            keyFile: nil,
            keyFileName: nil
        )
    )
}

private func temporaryTestFile(named name: String, contents: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepass-native-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try contents.write(to: url)
    return url
}

// MARK: - 读取与结构

@Test func keePassNativeDocumentReadsGroupTreeAndEntries() throws {
    let document = try loadFixture(container: .kdbx4)

    #expect(document.container == .kdbx4)
    #expect(document.groupCount == 2)
    #expect(document.entryCount == 2)
    #expect(document.groups.map(\.path) == ["Root", "Root/Team"])
    #expect(document.groups.map(\.depth) == [0, 1])
    #expect(document.groups.first?.isRoot == true)
    #expect(document.group(id: teamGroupUUID)?.isRecycleBin == true)

    let mail = try #require(document.entry(id: mailEntryUUID))
    #expect(mail.title == "Mail")
    #expect(mail.username == "me@example.com")
    #expect(mail.password == "s3cret-mail-password")
    #expect(mail.url == "https://mail.example.com")
    #expect(mail.notes == "mail notes")
    #expect(mail.groupID == rootGroupUUID)
    #expect(mail.protectedFieldKeys == ["Password"])

    let team = try #require(document.entries(inGroup: teamGroupUUID).first)
    #expect(team.title == "Deploy")
    #expect(team.password.isEmpty)
    #expect(team.protectedFieldKeys.isEmpty)
}

@Test func keePassNativeDocumentSearchesEntryFields() throws {
    let document = try loadFixture(container: .kdbx4)

    #expect(document.entries(matching: "mail").map(\.title) == ["Mail"])
    #expect(document.entries(matching: "ops").map(\.title) == ["Deploy"])
    #expect(document.entries(matching: "ssh://deploy").map(\.title) == ["Deploy"])
    #expect(document.entries(matching: "Root/Team").map(\.title) == ["Deploy"])
    #expect(document.entries(matching: "   ").isEmpty)
    #expect(document.entries(matching: "no-such-entry").isEmpty)
}

// MARK: - 编辑与保真

@Test func keePassNativeDocumentPreservesUnknownXMLWhenEditing() throws {
    let document = try loadFixture(container: .kdbx4)
    #expect(document.containsElement(named: "CustomVendorData"))
    #expect(document.containsElement(named: "AutoType"))
    #expect(document.containsElement(named: "History"))
    #expect(document.containsElement(named: "CustomVendorEntry"))
    #expect(document.textValues(forElementNamed: "CustomVendorData") == ["keep-me"])

    try document.updateEntry(
        id: mailEntryUUID,
        title: "Mail (edited)",
        username: "edited@example.com",
        password: "edited-password",
        url: "https://mail.example.com/edited",
        notes: "edited notes"
    )
    #expect(document.hasUnsavedChanges)

    let saved = try document.makeDatabaseData()
    let reopened = try KeePassNativeDocument.load(
        data: saved,
        sourceName: "fixture.kdbx",
        credentials: KeePassUnlockCredentials(password: fixturePassword, keyFile: nil, keyFileName: nil)
    )

    let mail = try #require(reopened.entry(id: mailEntryUUID))
    #expect(mail.title == "Mail (edited)")
    #expect(mail.username == "edited@example.com")
    #expect(mail.password == "edited-password")
    #expect(mail.url == "https://mail.example.com/edited")
    #expect(mail.notes == "edited notes")
    #expect(mail.protectedFieldKeys == ["Password"])

    // 未知节点、历史与 MemoryProtection 必须原样保留。
    #expect(reopened.containsElement(named: "CustomVendorData"))
    #expect(reopened.textValues(forElementNamed: "CustomVendorData") == ["keep-me"])
    #expect(reopened.containsElement(named: "CustomVendorEntry"))
    #expect(reopened.textValues(forElementNamed: "CustomVendorEntry") == ["keep-entry"])
    #expect(reopened.containsElement(named: "AutoType"))
    #expect(reopened.containsElement(named: "MemoryProtection"))
    #expect(reopened.containsElement(named: "History"))
    #expect(reopened.textValues(forElementNamed: "ProtectPassword") == ["True"])
    #expect(reopened.groups.map(\.path) == ["Root", "Root/Team"])
    #expect(!reopened.hasUnsavedChanges)
}

@Test func keePassNativeDocumentSavedDatabaseIsReadableByExistingReader() throws {
    let document = try loadFixture(container: .kdbx4)
    try document.updateEntry(
        id: mailEntryUUID,
        title: "Mail",
        username: "me@example.com",
        password: "reader-verified-password",
        url: "https://mail.example.com",
        notes: "mail notes"
    )
    let saved = try document.makeDatabaseData()

    let snapshot = try DefaultKeePassDatabaseReader().readSnapshot(
        database: saved,
        sourceName: "fixture.kdbx",
        credentials: KeePassUnlockCredentials(password: fixturePassword, keyFile: nil, keyFileName: nil)
    )
    #expect(snapshot.headerSummary?.formatVersion == .kdbx4)
    #expect(snapshot.groups.map(\.path) == ["/", "/Team"])
    let entry = try #require(snapshot.entries.first { $0.id == mailEntryUUID })
    #expect(entry.decodedPassword == "reader-verified-password")
    #expect(entry.title == "Mail")
}

@Test func keePassNativeDocumentDoesNotLeakPlaintextIntoDatabaseBytes() throws {
    let document = try loadFixture(container: .kdbx4)
    try document.updateEntry(
        id: mailEntryUUID,
        title: "Mail",
        username: "me@example.com",
        password: "unique-plaintext-marker-42",
        url: "https://mail.example.com",
        notes: "unique-notes-marker-42"
    )
    let saved = try document.makeDatabaseData()
    #expect(saved.range(of: Data("unique-plaintext-marker-42".utf8)) == nil)
    #expect(saved.range(of: Data("unique-notes-marker-42".utf8)) == nil)
    #expect(!document.structureSummary.contains("unique-plaintext-marker-42"))
    #expect(!document.displayName.contains("unique-plaintext-marker-42"))
}

@Test func keePassNativeDocumentReissuesFreshRandomParametersOnEverySave() throws {
    let document = try loadFixture(container: .kdbx4)
    let first = try document.makeDatabaseData()
    let second = try document.makeDatabaseData()
    #expect(first != second)
    #expect(first.count > 0)
    #expect(second.count > 0)

    // 两次写回都必须能被同一组凭据重新打开。
    for database in [first, second] {
        let reopened = try KeePassNativeDocument.load(
            data: database,
            sourceName: "fixture.kdbx",
            credentials: KeePassUnlockCredentials(password: fixturePassword, keyFile: nil, keyFileName: nil)
        )
        #expect(reopened.entry(id: mailEntryUUID)?.password == "s3cret-mail-password")
    }
}

// MARK: - 组操作

@Test func keePassNativeDocumentSupportsGroupCRUDWithValidation() throws {
    let document = try loadFixture(container: .kdbx4)

    let created = try document.createGroup(parentID: teamGroupUUID, title: "  Sub Team  ")
    #expect(created.title == "Sub Team")
    #expect(created.parentID == teamGroupUUID)
    #expect(created.path == "Root/Team/Sub Team")
    #expect(document.groupCount == 3)

    try document.renameGroup(id: created.id, title: "Renamed")
    #expect(document.group(id: created.id)?.title == "Renamed")

    try document.moveGroup(id: created.id, toParentID: rootGroupUUID)
    #expect(document.group(id: created.id)?.path == "Root/Renamed")

    #expect(throws: KeePassOperationError.self) {
        try document.moveGroup(id: rootGroupUUID, toParentID: nil)
    }
    #expect(throws: KeePassOperationError.self) {
        try document.renameGroup(id: created.id, title: "   ")
    }
    #expect(throws: KeePassOperationError.self) {
        try document.createGroup(parentID: "missing-group", title: "Nope")
    }

    // 父分组不能移动进自己的子树。
    let nested = try document.createGroup(parentID: teamGroupUUID, title: "Nested")
    #expect(throws: KeePassOperationError.self) {
        try document.moveGroup(id: teamGroupUUID, toParentID: nested.id)
    }

    try document.deleteGroup(id: created.id)
    #expect(document.group(id: created.id) == nil)
    #expect(throws: KeePassOperationError.self) {
        try document.deleteGroup(id: rootGroupUUID)
    }
    #expect(throws: KeePassOperationError.self) {
        try document.deleteGroup(id: teamGroupUUID)
    }

    let saved = try document.makeDatabaseData()
    let reopened = try KeePassNativeDocument.load(
        data: saved,
        sourceName: "fixture.kdbx",
        credentials: KeePassUnlockCredentials(password: fixturePassword, keyFile: nil, keyFileName: nil)
    )
    #expect(reopened.groups.map(\.path) == ["Root", "Root/Team", "Root/Team/Nested"])
}

@Test func keePassNativeDocumentRefusesToDeleteGroupContainingRecycleBin() throws {
    let document = try loadFixture(container: .kdbx4)

    // Team 组就是回收站分组，不能删除。
    #expect(throws: KeePassOperationError.self) {
        try document.deleteGroup(id: teamGroupUUID)
    }
    #expect(document.group(id: teamGroupUUID) != nil)

    // 包含回收站的父分组同样不能删除，否则 RecycleBinUUID 会悬空。
    let vault = try document.createGroup(parentID: rootGroupUUID, title: "Vault")
    try document.moveGroup(id: teamGroupUUID, toParentID: vault.id)
    #expect(document.group(id: teamGroupUUID)?.path == "Root/Vault/Team")
    #expect(throws: KeePassOperationError.self) {
        try document.deleteGroup(id: vault.id)
    }
    #expect(document.group(id: vault.id) != nil)
}

// MARK: - KDBX3

@Test func keePassNativeDocumentRoundTripsKdbx3() throws {
    let document = try loadFixture(container: .kdbx3)
    #expect(document.container == .kdbx3)
    #expect(document.entry(id: mailEntryUUID)?.password == "s3cret-mail-password")

    try document.renameGroup(id: teamGroupUUID, title: "Ops")
    try document.updateEntry(
        id: mailEntryUUID,
        title: "Mail",
        username: "me@example.com",
        password: "kdbx3-edited-password",
        url: "https://mail.example.com",
        notes: "v3 notes"
    )
    let saved = try document.makeDatabaseData()

    let reopened = try KeePassNativeDocument.load(
        data: saved,
        sourceName: "fixture-v3.kdbx",
        credentials: KeePassUnlockCredentials(password: fixturePassword, keyFile: nil, keyFileName: nil)
    )
    #expect(reopened.container == .kdbx3)
    #expect(reopened.entry(id: mailEntryUUID)?.password == "kdbx3-edited-password")
    #expect(reopened.groups.map(\.path) == ["Root", "Root/Ops"])
    #expect(reopened.containsElement(named: "CustomVendorEntry"))

    let snapshot = try DefaultKeePassDatabaseReader().readSnapshot(
        database: saved,
        sourceName: "fixture-v3.kdbx",
        credentials: KeePassUnlockCredentials(password: fixturePassword, keyFile: nil, keyFileName: nil)
    )
    #expect(snapshot.headerSummary?.formatVersion == .kdbx3)
    #expect(snapshot.entries.first { $0.id == mailEntryUUID }?.decodedPassword == "kdbx3-edited-password")
}

// MARK: - 凭据失败

@Test func keePassNativeDocumentRejectsWrongPassword() throws {
    let database = try makeDatabase(container: .kdbx4)
    #expect(throws: KeePassOperationError.self) {
        _ = try KeePassNativeDocument.load(
            data: database,
            sourceName: "fixture.kdbx",
            credentials: KeePassUnlockCredentials(password: "wrong-password", keyFile: nil, keyFileName: nil)
        )
    }
    #expect(throws: KeePassOperationError.self) {
        _ = try KeePassNativeDocument.load(
            data: database,
            sourceName: "fixture.kdbx",
            credentials: KeePassUnlockCredentials(password: "", keyFile: nil, keyFileName: nil)
        )
    }
}

@Test func keePassNativeDocumentRejectsUnknownFormat() throws {
    #expect(throws: KeePassOperationError.self) {
        _ = try KeePassNativeDocument.load(
            data: Data("this is not a kdbx".utf8),
            sourceName: "notes.txt",
            credentials: KeePassUnlockCredentials(password: fixturePassword, keyFile: nil, keyFileName: nil)
        )
    }
}

// MARK: - 安全写回

@Test func keePassNativeDocumentStoreWritesVerifiedDatabase() throws {
    let document = try loadFixture(container: .kdbx4)
    let originalURL = try temporaryTestFile(named: "vault.kdbx", contents: try makeDatabase(container: .kdbx4))
    defer {
        try? FileManager.default.removeItem(at: originalURL.deletingLastPathComponent())
    }

    try document.renameGroup(id: teamGroupUUID, title: "Renamed Team")
    let outcome = try KeePassNativeDocumentStore().save(document: document, to: originalURL)
    #expect(outcome.entryCount == 2)
    #expect(outcome.databaseByteCount > 0)

    let reloaded = try KeePassNativeDocument.load(
        data: Data(contentsOf: originalURL),
        sourceName: "vault.kdbx",
        credentials: KeePassUnlockCredentials(password: fixturePassword, keyFile: nil, keyFileName: nil)
    )
    #expect(reloaded.groups.map(\.title) == ["Root", "Renamed Team"])
    #expect(reloaded.entry(id: mailEntryUUID)?.password == "s3cret-mail-password")
    #expect(reloaded.containsElement(named: "CustomVendorEntry"))
    #expect(!reloaded.hasUnsavedChanges)
}

@Test func keePassNativeDocumentStoreLeavesSourceUntouchedWhenVerificationFails() throws {
    let store = KeePassNativeDocumentStore()
    let originalDatabase = try makeDatabase(container: .kdbx4)
    let url = try temporaryTestFile(named: "vault.kdbx", contents: originalDatabase)
    defer {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    let credentials = KeePassUnlockCredentials(password: fixturePassword, keyFile: nil, keyFileName: nil)
    let document = try KeePassNativeDocument.load(
        data: originalDatabase,
        sourceName: "vault.kdbx",
        credentials: credentials
    )

    // 1) 未知格式：绝不覆盖。
    #expect(throws: KeePassOperationError.self) {
        try store.replaceVerified(
            database: Data("garbage".utf8),
            credentials: credentials,
            expectedContentSignature: document.contentSignature,
            at: url
        )
    }
    #expect(try Data(contentsOf: url) == originalDatabase)

    // 2) 错误口令：能写出文件但无法重新打开，绝不覆盖。
    #expect(throws: KeePassOperationError.self) {
        try store.replaceVerified(
            database: originalDatabase,
            credentials: KeePassUnlockCredentials(password: "wrong", keyFile: nil, keyFileName: nil),
            expectedContentSignature: document.contentSignature,
            at: url
        )
    }
    #expect(try Data(contentsOf: url) == originalDatabase)

    // 3) 内容签名不一致：说明写回内容与当前编辑状态不符，绝不覆盖。
    let validDatabase = try document.makeDatabaseData()
    #expect(throws: KeePassOperationError.self) {
        try store.replaceVerified(
            database: validDatabase,
            credentials: credentials,
            expectedContentSignature: "stale-signature",
            at: url
        )
    }
    #expect(try Data(contentsOf: url) == originalDatabase)

    // 失败后目录里不应残留临时文件。
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    #expect(leftovers == ["vault.kdbx"])
}

@Test func keePassNativeDocumentStoreRejectsUnknownVersionDatabase() throws {
    let store = KeePassNativeDocumentStore()
    let url = try temporaryTestFile(
        named: "vault.kdbx",
        contents: Data(repeating: 0x00, count: 64)
    )
    defer {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    let original = try Data(contentsOf: url)
    #expect(throws: KeePassOperationError.self) {
        try store.replaceVerified(
            database: Data(repeating: 0x01, count: 32),
            credentials: KeePassUnlockCredentials(password: "pw", keyFile: nil, keyFileName: nil),
            expectedContentSignature: "any",
            at: url
        )
    }
    #expect(try Data(contentsOf: url) == original)
}

// MARK: - 生命周期

@Test func keePassNativeDocumentCloseDropsStateAndBlocksFurtherWrites() throws {
    let document = try loadFixture(container: .kdbx4)
    #expect(document.entryCount == 2)
    document.close()
    #expect(document.isClosed)
    #expect(document.groups.isEmpty)
    #expect(document.entryCount == 0)
    #expect(document.allEntries.isEmpty)
    #expect(document.entries(matching: "Mail").isEmpty)
    #expect(!document.hasUnsavedChanges)
    #expect(throws: KeePassOperationError.self) {
        _ = try document.makeDatabaseData()
    }
    // 幂等关闭。
    document.close()
    #expect(document.isClosed)
}


@Test func keePassNativeDocumentCreatesProtectedEntry() throws {
    let document = try loadFixture(container: .kdbx4)
    let created = try document.createEntry(
        groupID: teamGroupUUID,
        title: "SSH",
        username: "ops",
        password: "created-secret",
        url: "ssh://example.com",
        notes: "created notes"
    )
    #expect(created.groupPath == "Root/Team")
    #expect(created.password == "created-secret")
    #expect(created.protectedFieldKeys == ["Password"])
    #expect(document.hasUnsavedChanges)

    let saved = try document.makeDatabaseData()
    #expect(saved.contains(Data("created-secret".utf8)) == false)

    let reopened = try KeePassNativeDocument.load(
        data: saved,
        sourceName: "fixture.kdbx",
        credentials: KeePassUnlockCredentials(password: fixturePassword, keyFile: nil, keyFileName: nil)
    )
    #expect(reopened.entry(id: created.id)?.password == "created-secret")
    #expect(reopened.entry(id: created.id)?.notes == "created notes")

    let snapshot = try DefaultKeePassDatabaseReader().readSnapshot(
        database: saved,
        sourceName: "fixture.kdbx",
        credentials: KeePassUnlockCredentials(password: fixturePassword, keyFile: nil, keyFileName: nil)
    )
    #expect(snapshot.entries.first { $0.title == "SSH" }?.decodedPassword == "created-secret")

    #expect(document.hasUnsavedChanges)
    document.markSaved()
    #expect(document.hasUnsavedChanges == false)
}

@Test func keePassNativeDocumentPreservesHeaderAndProtectedFieldStrategy() throws {
    let document = try loadFixture(container: .kdbx4)
    let originalCipher = document.cipher
    let originalCompression = document.compression
    let originalKdfParameters = document.kdfParameters
    let originalStreamID = document.innerRandomStreamID

    try document.updateEntry(
        id: mailEntryUUID,
        title: "Mail",
        username: "me@example.com",
        password: "header-preserving-password",
        url: "https://mail.example.com",
        notes: ""
    )
    let saved = try document.makeDatabaseData()
    let reopened = try KeePassNativeDocument.load(
        data: saved,
        sourceName: "fixture.kdbx",
        credentials: KeePassUnlockCredentials(password: fixturePassword, keyFile: nil, keyFileName: nil)
    )

    // KDF 参数与加密 / 压缩算法必须原样沿用，只有随机参数（master seed / IV）会换新。
    #expect(reopened.cipher == originalCipher)
    #expect(reopened.compression == originalCompression)
    #expect(reopened.kdfParameters == originalKdfParameters)
    #expect(reopened.innerRandomStreamID == originalStreamID)
    #expect(reopened.entry(id: mailEntryUUID)?.password == "header-preserving-password")
    #expect(reopened.textValues(forElementNamed: "ProtectPassword") == ["True"])
}
