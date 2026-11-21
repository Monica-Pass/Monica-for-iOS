import Testing
import Foundation
import MonicaStorage

@Suite("笔记草稿加密存储")
struct NoteDraftStoreTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-note-draft-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(
        directory: URL,
        key: Data = NoteDraftKeyGenerator.makeKey()
    ) -> NoteDraftStore {
        NoteDraftStore(directoryURL: directory, keyProvider: StaticNoteDraftKeyProvider(key: key))
    }

    @Test func savesAndLoadsDraft() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let draft = NoteDraft(
            draftID: "new-note",
            noteID: nil,
            title: "会议记录",
            body: "# 标题\n\n- 第一项\n![图](monica-attachment://abc)",
            updatedAt: updatedAt
        )

        try store.saveDraft(draft)

        let loaded = try store.loadDraft(draftID: "new-note")
        #expect(loaded == draft)
        #expect(loaded?.schemaVersion == NoteDraft.currentSchemaVersion)
        #expect(store.draftExists(draftID: "new-note"))
    }

    @Test func neverWritesDraftPlaintextToDisk() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        let secretBody = "# 私密正文\n银行卡 1234 5678"
        let secretTitle = "私密标题"
        try store.saveDraft(NoteDraft(draftID: "note-1", noteID: "note-1", title: secretTitle, body: secretBody))

        let fileURL = store.fileURL(forDraftID: "note-1")
        #expect(fileURL.pathExtension == NoteDraftStore.fileExtension)
        let raw = try Data(contentsOf: fileURL)
        #expect(raw.range(of: Data(secretBody.utf8)) == nil)
        #expect(raw.range(of: Data(secretTitle.utf8)) == nil)
        // 文件应为 8 字节魔数 + 至少 nonce/tag 的密文，长度必须大于明文。
        #expect(raw.count > secretBody.utf8.count)
    }

    @Test func refusesToDecryptWithWrongKey() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyStore = makeStore(directory: directory, key: NoteDraftKeyGenerator.makeKey())
        try keyStore.saveDraft(NoteDraft(draftID: "note-1", noteID: "note-1", title: "标题", body: "正文"))

        let otherStore = makeStore(directory: directory, key: NoteDraftKeyGenerator.makeKey())
        #expect(throws: NoteDraftStoreError.corruptedDraft) {
            try otherStore.loadDraft(draftID: "note-1")
        }
    }

    @Test func returnsNilForMissingDraft() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        #expect(try store.loadDraft(draftID: "absent") == nil)
    }

    @Test func deletesDraftCompletely() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        try store.saveDraft(NoteDraft(draftID: "note-1", noteID: "note-1", title: "标题", body: "正文"))
        let fileURL = store.fileURL(forDraftID: "note-1")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        try store.deleteDraft(draftID: "note-1")

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try store.loadDraft(draftID: "note-1") == nil)
        // 重复删除不报错。
        try store.deleteDraft(draftID: "note-1")
    }

    @Test func overwritesExistingDraft() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        try store.saveDraft(NoteDraft(draftID: "note-1", noteID: "note-1", title: "旧", body: "旧正文"))
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try store.saveDraft(NoteDraft(draftID: "note-1", noteID: "note-1", title: "新", body: "新正文", updatedAt: updatedAt))

        let loaded = try store.loadDraft(draftID: "note-1")
        #expect(loaded?.title == "新")
        #expect(loaded?.body == "新正文")
        #expect(loaded?.updatedAt == updatedAt)
    }

    @Test func listsDraftsNewestFirstAndSkipsCorruptedFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        try store.saveDraft(NoteDraft(
            draftID: "older",
            noteID: "older",
            title: "旧草稿",
            body: "",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try store.saveDraft(NoteDraft(
            draftID: "newer",
            noteID: "newer",
            title: "新草稿",
            body: "",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        // 手工放入一个损坏文件，列表必须跳过而不是整体失败。
        try Data("not a draft".utf8).write(
            to: directory.appendingPathComponent("broken.\(NoteDraftStore.fileExtension)")
        )

        let drafts = try store.listDrafts()
        #expect(drafts.map(\.draftID) == ["newer", "older"])
    }

    @Test func rejectsInvalidKeysAndIdentifiers() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let shortKeyStore = makeStore(directory: directory, key: Data(repeating: 1, count: 16))
        #expect(throws: NoteDraftStoreError.invalidKey) {
            try shortKeyStore.saveDraft(NoteDraft(draftID: "note-1", noteID: nil, title: "a", body: "b"))
        }

        let goodStore = makeStore(directory: directory)
        #expect(throws: NoteDraftStoreError.invalidDraftID) {
            try goodStore.saveDraft(NoteDraft(draftID: "../../escape", noteID: nil, title: "a", body: "b"))
        }
        #expect(throws: NoteDraftStoreError.invalidDraftID) {
            try goodStore.loadDraft(draftID: "note/1")
        }
        #expect(goodStore.fileURL(forDraftID: "note-1").path.hasPrefix(directory.path))
    }

    @Test func reportsKeyProviderFailureAsInvalidKey() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        struct FailingKeyProvider: NoteDraftKeyProviding {
            struct Failure: Error {}
            func noteDraftKey() throws -> Data {
                throw Failure()
            }
        }
        let store = NoteDraftStore(directoryURL: directory, keyProvider: FailingKeyProvider())
        #expect(throws: NoteDraftStoreError.invalidKey) {
            try store.saveDraft(NoteDraft(draftID: "note-1", noteID: nil, title: "a", body: "b"))
        }
    }

    @Test func deletesAllDrafts() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        for index in 0..<3 {
            try store.saveDraft(NoteDraft(draftID: "note-\(index)", noteID: "note-\(index)", title: "\(index)", body: ""))
        }
        try store.deleteAllDrafts()
        #expect(try store.listDrafts().isEmpty)
        // 目录还在，但草稿文件都删掉了。
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func validatesDraftIdentifierFormat() {
        #expect(NoteDraftStore.isSupportedDraftID("new-note"))
        #expect(NoteDraftStore.isSupportedDraftID("A1B2-C3_D4"))
        #expect(!NoteDraftStore.isSupportedDraftID(""))
        #expect(!NoteDraftStore.isSupportedDraftID("."))
        #expect(!NoteDraftStore.isSupportedDraftID(".."))
        #expect(!NoteDraftStore.isSupportedDraftID("a b"))
        #expect(!NoteDraftStore.isSupportedDraftID("a/b"))
        #expect(!NoteDraftStore.isSupportedDraftID(String(repeating: "a", count: 129)))
    }
}
