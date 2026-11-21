//
//  AppKeePassCloudBrowserTests.swift
//  MonicaTests
//
//  issue #33：云端 KeePass 浏览器的降级、临时明文清理与冲突检测。
//

@testable import Monica
import MonicaSync
import XCTest

@MainActor
final class AppKeePassCloudBrowserTests: XCTestCase {
    private func makeTemporaryDirectory() -> AppKeePassCloudTemporaryDirectory {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppKeePassCloudBrowserTests-\(UUID().uuidString)", isDirectory: true)
        return AppKeePassCloudTemporaryDirectory(baseDirectoryURL: base)
    }

    func testUnconfiguredGoogleDriveIsDisabledWithoutBlockingOneDrive() async throws {
        let environment = MonicaAppEnvironment()
        let model = AppKeePassCloudBrowserModel(
            browsers: environment.productionCloudFileBrowsers,
            temporaryDirectory: makeTemporaryDirectory(),
            initialKind: .googleDrive
        )

        XCTAssertTrue(model.hasAnyProvider)
        XCTAssertEqual(model.availableKinds, [.oneDrive, .googleDrive])
        guard case .notConfigured(let reason) = model.availability(for: .googleDrive) else {
            return XCTFail("未配置的 Google Drive 必须降级为 notConfigured")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertFalse(model.canBrowseSelectedProvider)

        await model.select(kind: .googleDrive)
        XCTAssertNil(model.page)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNotNil(model.errorMessage)

        // 未配置不影响 OneDrive。
        XCTAssertTrue(model.availability(for: .oneDrive).isAvailable)
        model.cleanupTemporaryFiles()
    }

    func testTemporaryDirectoryWritesProtectedFileAndCleansUp() throws {
        let directory = makeTemporaryDirectory()
        let file = try directory.write(Data("kdbx-secret-bytes".utf8), preferredName: "Vault.kdbx")

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(file.byteCount, 16)
        XCTAssertTrue(file.fileName.hasSuffix(".kdbx"))
        XCTAssertEqual(file.fileName.split(separator: "/").count, 1)

        let values = try file.url.resourceValues(forKeys: [.isExcludedFromBackupKey, .fileProtectionKey])
        XCTAssertEqual(values.fileProtection, .complete)
        XCTAssertEqual(directory.remainingFileNames.count, 1)

        directory.removeAll()
        XCTAssertTrue(directory.remainingFileNames.isEmpty)
    }

    func testSaveDetectsRemoteChangeAndSavesCopyInsteadOfOverwriting() async throws {
        let browser = StubCloudFileBrowser(kind: .oneDrive)
        let directory = makeTemporaryDirectory()
        let model = AppKeePassCloudBrowserModel(
            browsers: [.oneDrive: browser],
            temporaryDirectory: directory,
            initialKind: .oneDrive
        )

        await model.reload()
        let entry = try XCTUnwrap(model.entries.first)
        let opened = try await model.openDatabase(entry)
        XCTAssertEqual(opened.marker.revision, "rev-1")
        XCTAssertEqual(opened.temporaryFile.byteCount, browser.data.count)

        // 其他设备在这段时间更新了文件。
        browser.remoteRevision = "rev-2"
        do {
            _ = try await model.save(Data("edited".utf8), to: opened)
            XCTFail("云端版本已变化时不得覆盖写入")
        } catch let error as AppKeePassCloudBrowserError {
            guard case .conflict(let kind, let fileName, let latestRevision) = error else {
                return XCTFail("应报冲突，实际为 \(error)")
            }
            XCTAssertEqual(kind, .oneDrive)
            XCTAssertEqual(fileName, "Vault.kdbx")
            XCTAssertEqual(latestRevision, "rev-2")
        }
        XCTAssertTrue(browser.overwrites.isEmpty)

        let receipt = try await model.saveCopy(
            Data("edited".utf8),
            of: opened,
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(receipt.name, "Vault-copy-19700101-000000.kdbx")
        XCTAssertEqual(browser.uploads.last?.fileName, receipt.name)

        model.cleanupTemporaryFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.temporaryFile.url.path))
    }

    func testSaveOverwritesWithDownloadedRevisionWhenUnchanged() async throws {
        let browser = StubCloudFileBrowser(kind: .oneDrive)
        let model = AppKeePassCloudBrowserModel(
            browsers: [.oneDrive: browser],
            temporaryDirectory: makeTemporaryDirectory(),
            initialKind: .oneDrive
        )

        await model.reload()
        let entry = try XCTUnwrap(model.entries.first)
        let opened = try await model.openDatabase(entry)
        let receipt = try await model.save(Data("edited".utf8), to: opened)

        XCTAssertEqual(browser.overwrites.count, 1)
        XCTAssertEqual(browser.overwrites.first?.entryID, entry.id)
        XCTAssertEqual(browser.overwrites.first?.expectedRevision, "rev-1")
        XCTAssertEqual(browser.overwrites.first?.byteCount, 6)
        XCTAssertEqual(receipt.name, "Vault.kdbx")
        model.cleanupTemporaryFiles()
    }
}

private final class StubCloudFileBrowser: CloudFileBrowser, @unchecked Sendable {
    let kind: CloudFileBrowserKind
    var availability: CloudFileBrowserAvailability = .available
    var remoteRevision = "rev-1"
    var data = Data("kdbx-bytes".utf8)
    private(set) var overwrites: [(entryID: String, expectedRevision: String?, byteCount: Int)] = []
    private(set) var uploads: [(fileName: String, directoryID: String?)] = []

    init(kind: CloudFileBrowserKind) {
        self.kind = kind
    }

    func connectionState() async throws -> CloudFileConnectionState {
        .connected(accountLabel: "stub")
    }

    func browse(
        directoryID: String?,
        pageToken: String?,
        pageSize: Int,
        filter: CloudFileBrowserFilter
    ) async throws -> CloudFileBrowserPage {
        CloudFileBrowserPage(
            entries: [
                CloudFileBrowserEntry(
                    id: "file-1",
                    name: "Vault.kdbx",
                    path: "Vault.kdbx",
                    isDirectory: false,
                    byteCount: data.count,
                    revision: remoteRevision
                )
            ],
            nextPageToken: nil,
            totalCount: 1
        )
    }

    func download(entryID: String) async throws -> CloudFileDownload {
        CloudFileDownload(
            item: CloudFileItem(
                id: entryID,
                name: "Vault.kdbx",
                path: "Vault.kdbx",
                byteCount: data.count,
                revision: remoteRevision
            ),
            data: data,
            revision: remoteRevision
        )
    }

    func upload(
        named fileName: String,
        data: Data,
        in directoryID: String?,
        expectedRevision: String?
    ) async throws -> CloudFileBrowserWriteReceipt {
        uploads.append((fileName, directoryID))
        return CloudFileBrowserWriteReceipt(
            kind: kind,
            itemID: fileName,
            name: fileName,
            byteCount: data.count,
            sha256: "stub-sha",
            revision: remoteRevision
        )
    }

    func overwrite(
        entryID: String,
        data: Data,
        expectedRevision: String?
    ) async throws -> CloudFileBrowserWriteReceipt {
        overwrites.append((entryID, expectedRevision, data.count))
        return CloudFileBrowserWriteReceipt(
            kind: kind,
            itemID: entryID,
            name: "Vault.kdbx",
            byteCount: data.count,
            sha256: "stub-sha",
            revision: remoteRevision
        )
    }
}
