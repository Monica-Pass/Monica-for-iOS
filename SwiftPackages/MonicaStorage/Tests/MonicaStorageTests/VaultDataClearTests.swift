//
//  VaultDataClearTests.swift
//  MonicaStorageTests
//
//  issue #145「按数据类型清空（主密码确认）」的存储层测试。
//  覆盖：只清所选类型、主密码错误时零删除、空库行为、跨项目统计与附件悬空引用清理。
//

import Foundation
import MonicaStorage
import Testing

@Suite("按数据类型清空")
struct VaultDataClearTests {
    private struct Fixture {
        let engine: RecordingVaultEngine
        let repository: LocalVaultRepository
        let session: LocalVaultSession
        let entryRepository: LocalVaultEntryRepository
        let service: VaultDataClearService
    }

    private func makeFixture() throws -> Fixture {
        let engine = RecordingVaultEngine()
        let repository = LocalVaultRepository(engine: engine)
        let session = try repository.createVault(
            named: "Issue145",
            in: FileManager.default.temporaryDirectory,
            password: "master-password",
            deviceID: "issue-145-device"
        )
        let entryRepository = repository.entryRepository(for: session)
        return Fixture(
            engine: engine,
            repository: repository,
            session: session,
            entryRepository: entryRepository,
            service: VaultDataClearService(repository: repository, session: session)
        )
    }

    private func makeProject(
        _ fixture: Fixture,
        title: String
    ) throws -> LocalVaultProject {
        try fixture.entryRepository.createProject(title: title)
    }

    private func makeLogin(
        _ fixture: Fixture,
        projectID: String,
        title: String
    ) throws -> LocalLoginEntry {
        try fixture.entryRepository.createLoginEntry(
            projectID: projectID,
            draft: LocalLoginEntryDraft(
                title: title,
                username: "user-\(title)",
                password: "secret",
                url: "https://example.com",
                notes: ""
            )
        )
    }

    private func makeNote(
        _ fixture: Fixture,
        projectID: String,
        title: String
    ) throws -> LocalNoteEntry {
        try fixture.entryRepository.createNoteEntry(
            projectID: projectID,
            draft: LocalNoteEntryDraft(title: title, body: "body")
        )
    }

    @Test func clearRemovesOnlySelectedKindsAndKeepsProjects() throws {
        let fixture = try makeFixture()
        let personal = try makeProject(fixture, title: "个人")
        let work = try makeProject(fixture, title: "工作")
        _ = try makeLogin(fixture, projectID: personal.id, title: "邮箱")
        _ = try makeLogin(fixture, projectID: work.id, title: "后台")
        _ = try makeNote(fixture, projectID: personal.id, title: "随笔")
        _ = try makeNote(fixture, projectID: work.id, title: "会议")

        let report = try fixture.service.clear(
            kinds: [.login],
            masterPassword: "master-password"
        )

        #expect(report.deletedCounts[.login] == 2)
        #expect(report.deletedCounts[.note] == nil)
        #expect(report.totalDeletedCount == 2)

        // 只删登录：两个项目的登录都进入回收站，笔记原样保留。
        #expect(try fixture.entryRepository.listLoginEntries(projectID: personal.id).isEmpty)
        #expect(try fixture.entryRepository.listLoginEntries(projectID: work.id).isEmpty)
        #expect(try fixture.entryRepository.listNoteEntries(projectID: personal.id).count == 1)
        #expect(try fixture.entryRepository.listNoteEntries(projectID: work.id).count == 1)

        // 软删除：可恢复，且项目/分类结构没有被删掉。
        #expect(try fixture.entryRepository.listDeletedLoginEntries(projectID: personal.id).count == 1)
        #expect(try fixture.entryRepository.listDeletedLoginEntries(projectID: work.id).count == 1)
        #expect(try fixture.entryRepository.listProjects().count == 2)
        #expect(fixture.engine.deletedLoginEntries.count == 2)
        #expect(fixture.engine.deletedProjects.isEmpty)
    }

    @Test func wrongMasterPasswordDeletesNothing() throws {
        let fixture = try makeFixture()
        let project = try makeProject(fixture, title: "个人")
        _ = try makeLogin(fixture, projectID: project.id, title: "邮箱")
        _ = try makeNote(fixture, projectID: project.id, title: "随笔")
        fixture.engine.verifyMasterPasswordError = LocalVaultRepositoryError.currentPasswordMismatch

        #expect(throws: LocalVaultRepositoryError.self) {
            try fixture.service.clear(
                kinds: [.login, .note],
                masterPassword: "wrong-password"
            )
        }

        // 主密码错误时一条都不许删。
        #expect(try fixture.entryRepository.listLoginEntries(projectID: project.id).count == 1)
        #expect(try fixture.entryRepository.listNoteEntries(projectID: project.id).count == 1)
        #expect(fixture.engine.deletedLoginEntries.isEmpty)
        #expect(fixture.engine.deletedNoteEntries.isEmpty)
        #expect(fixture.engine.verifiedMasterPasswords.count == 1)
        #expect(fixture.engine.verifiedMasterPasswords.first?.password == "wrong-password")
    }

    @Test func clearRejectsSessionOfAnotherVaultWithoutDeleting() throws {
        let fixture = try makeFixture()
        let project = try makeProject(fixture, title: "个人")
        _ = try makeLogin(fixture, projectID: project.id, title: "邮箱")
        fixture.engine.verifyMasterPasswordVaultID = "another-vault"

        #expect(throws: LocalVaultRepositoryError.self) {
            try fixture.service.clear(
                kinds: [.login],
                masterPassword: "master-password"
            )
        }
        #expect(try fixture.entryRepository.listLoginEntries(projectID: project.id).count == 1)
        #expect(fixture.engine.deletedLoginEntries.isEmpty)
    }

    @Test func clearOnEmptyVaultReturnsZeroAndSucceeds() throws {
        let fixture = try makeFixture()
        _ = try makeProject(fixture, title: "空分类")

        let report = try fixture.service.clear(
            kinds: [.login, .note, .totp, .card, .identity],
            masterPassword: "master-password"
        )

        #expect(report.totalDeletedCount == 0)
        #expect(report.removedTagCount == 0)
        #expect(fixture.engine.deletedLoginEntries.isEmpty)
    }

    @Test func countsSumAcrossProjectsAndIgnoreUnsupportedKinds() throws {
        let fixture = try makeFixture()
        let personal = try makeProject(fixture, title: "个人")
        let work = try makeProject(fixture, title: "工作")
        _ = try makeLogin(fixture, projectID: personal.id, title: "邮箱")
        _ = try makeLogin(fixture, projectID: work.id, title: "后台")
        _ = try makeNote(fixture, projectID: personal.id, title: "随笔")

        let counts = try fixture.service.counts()

        #expect(counts[.login] == 2)
        #expect(counts[.note] == 1)
        #expect(counts[.totp] == 0)
        // 录制引擎不支持的类型按 0 计，不能阻断设置页。
        #expect(counts[.sso] == 0)
        #expect(counts[.steam] == 0)
        #expect(counts[.attachmentRef] == 0)
    }

    @Test func clearRemovesAttachmentReferencesPointingAtDeletedEntries() throws {
        let fixture = try makeFixture()
        let project = try makeProject(fixture, title: "个人")
        let login = try makeLogin(fixture, projectID: project.id, title: "邮箱")
        let note = try makeNote(fixture, projectID: project.id, title: "随笔")
        for (entryID, fileName) in [(login.id, "login.pdf"), (note.id, "note.pdf")] {
            _ = try fixture.engine.createAttachmentMetadata(
                in: fixture.session.handle,
                projectID: project.id,
                entryID: entryID,
                fileName: fileName,
                mediaType: "application/pdf",
                originalSize: 4,
                storedSize: 4,
                contentHash: "hash-\(fileName)",
                storageMode: "local",
                source: "",
                downloadState: "",
                wrappedContentEncryptionKey: nil,
                localPath: nil
            )
        }

        let report = try fixture.service.clear(
            kinds: [.login],
            masterPassword: "master-password"
        )

        // 登录的附件引用被顺带清掉，笔记的附件引用不受影响。
        #expect(report.deletedCounts[.login] == 1)
        #expect(report.deletedCounts[.attachmentRef] == 1)
        let attachments = try fixture.entryRepository.listAttachmentMetadata(projectID: project.id)
        #expect(attachments.map(\.fileName) == ["note.pdf"])
    }
}
