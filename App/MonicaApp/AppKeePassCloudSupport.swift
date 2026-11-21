//
//  AppKeePassCloudSupport.swift
//  Monica
//
//  「云端 KeePass 文件」的临时明文存储、浏览状态与冲突检测。
//

import Foundation
import MonicaSync
import Observation

enum AppKeePassCloudBrowserError: LocalizedError, Equatable {
    case noProviderAvailable
    case providerNotConfigured(CloudFileBrowserKind)
    case providerUnavailable(CloudFileBrowserKind)
    case notADirectory(CloudFileBrowserKind)
    case notAKeePassDatabase(CloudFileBrowserKind)
    case missingOpenedFile
    case googleDriveNotConnected
    case conflict(kind: CloudFileBrowserKind, fileName: String, latestRevision: String?)

    var errorDescription: String? {
        switch self {
        case .noProviderAvailable:
            return String(localized: "没有可用的云端文件来源。")
        case .providerNotConfigured(let kind):
            return String(localized: "\(kind.displayName) 未配置，无法浏览云端 KeePass 文件。")
        case .providerUnavailable(let kind):
            return String(localized: "\(kind.displayName) 当前不可用。")
        case .notADirectory:
            return String(localized: "该条目不是目录。")
        case .notAKeePassDatabase:
            return String(localized: "只能打开 .kdbx 数据库文件。")
        case .missingOpenedFile:
            return String(localized: "请先打开一个云端文件。")
        case .googleDriveNotConnected:
            return String(localized: "请先登录 Google Drive。")
        case .conflict(_, let fileName, _):
            return String(localized: "云端 \(fileName) 已被其他设备修改，未覆盖。请另存副本。")
        }
    }
}

struct AppKeePassCloudTemporaryFile: Sendable, Equatable, Identifiable {
    let url: URL
    let byteCount: Int

    var id: String { url.absoluteString }

    var fileName: String { url.lastPathComponent }

    func removingFromDisk(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: url)
    }
}

/// 下载的 `.kdbx` 明文只落在这个目录：受数据保护、排除备份、用完即删。
struct AppKeePassCloudTemporaryDirectory {
    let directoryURL: URL
    private let fileManager: FileManager

    init(
        baseDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let base = baseDirectoryURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let url = base.appendingPathComponent("KeePassCloudTemp", isDirectory: true)
        try? fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
        self.directoryURL = url
    }

    func write(_ data: Data, preferredName: String) throws -> AppKeePassCloudTemporaryFile {
        let sanitized = CloudFileKeePassFile.sanitizedName(preferredName)
        let url = directoryURL.appendingPathComponent("\(UUID().uuidString)-\(sanitized)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        return AppKeePassCloudTemporaryFile(url: url, byteCount: data.count)
    }

    func removeAll() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }

    var remainingFileNames: [String] {
        (try? fileManager.contentsOfDirectory(atPath: directoryURL.path)) ?? []
    }
}

struct AppKeePassCloudOpenedFile: Sendable, Equatable, Identifiable {
    let provider: CloudFileProviderKind
    let kind: CloudFileBrowserKind
    let entry: CloudFileBrowserEntry
    let download: CloudFileDownload
    let marker: CloudFileVersionMarker
    let temporaryFile: AppKeePassCloudTemporaryFile

    var id: String { "\(kind.rawValue)-\(entry.id)" }

    var redactedSummary: String {
        String(localized: "\(kind.displayName) \(CloudFileKeePassFile.sanitizedName(entry.name)) \(download.data.count) 字节")
    }
}

enum AppKeePassCloudCopyName {
    static func make(baseName: String, now: Date = Date()) -> String {
        let sanitized = CloudFileKeePassFile.sanitizedName(baseName)
        let stem = sanitized.lowercased().hasSuffix(".kdbx")
            ? String(sanitized.dropLast(5))
            : sanitized
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(stem)-copy-\(formatter.string(from: now)).kdbx"
    }
}

@MainActor
@Observable
final class AppKeePassCloudBrowserModel {
    private let browsers: [CloudFileBrowserKind: any CloudFileBrowser]
    private let googleDriveAuthentication: (any AppGoogleDriveAuthenticationService)?
    private let temporaryDirectory: AppKeePassCloudTemporaryDirectory

    private(set) var selectedKind: CloudFileBrowserKind
    private(set) var page: CloudFileBrowserPage?
    private(set) var directoryStack: [CloudFileBrowserEntry] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var googleDriveState: AppGoogleDriveConnectionState = .disconnected
    private(set) var openedFile: AppKeePassCloudOpenedFile?
    private(set) var filter: CloudFileBrowserFilter = .keePassOnly

    init(
        browsers: [CloudFileBrowserKind: any CloudFileBrowser],
        googleDriveAuthentication: (any AppGoogleDriveAuthenticationService)? = nil,
        temporaryDirectory: AppKeePassCloudTemporaryDirectory = AppKeePassCloudTemporaryDirectory(),
        initialKind: CloudFileBrowserKind? = nil
    ) {
        self.browsers = browsers
        self.googleDriveAuthentication = googleDriveAuthentication
        self.temporaryDirectory = temporaryDirectory
        self.selectedKind = initialKind
            ?? browsers.keys.sorted { $0.rawValue < $1.rawValue }.first
            ?? .oneDrive
    }

    var availableKinds: [CloudFileBrowserKind] {
        CloudFileBrowserKind.allCases.filter { browsers[$0] != nil }
    }

    var hasAnyProvider: Bool { !browsers.isEmpty }

    var entries: [CloudFileBrowserEntry] { page?.entries ?? [] }

    var currentDirectoryName: String {
        directoryStack.last.map { CloudFileKeePassFile.sanitizedName($0.name) }
            ?? String(localized: "云端根目录")
    }

    var canGoUp: Bool { !directoryStack.isEmpty }

    var canLoadNextPage: Bool { page?.hasMore == true }

    func availability(for kind: CloudFileBrowserKind) -> CloudFileBrowserAvailability {
        guard let browser = browsers[kind] else {
            return .notConfigured(reason: String(localized: "尚未接入"))
        }
        return browser.availability
    }

    var selectedAvailability: CloudFileBrowserAvailability {
        availability(for: selectedKind)
    }

    var canBrowseSelectedProvider: Bool { selectedAvailability.isAvailable }

    /// 只有 CloudFileProviderKind 覆盖的来源才能回到会话的写回路径；WebDAV 目前只读浏览。
    var selectedProviderKind: CloudFileProviderKind? {
        selectedKind.cloudFileProviderKind
    }

    var currentDirectoryID: String? { directoryStack.last?.id }

    func select(kind: CloudFileBrowserKind) async {
        guard selectedKind != kind || page == nil else {
            return
        }
        selectedKind = kind
        page = nil
        directoryStack = []
        errorMessage = nil
        statusMessage = nil
        openedFile = nil
        guard browsers[kind] != nil else {
            errorMessage = AppKeePassCloudBrowserError.providerUnavailable(kind).localizedDescription
            return
        }
        guard availability(for: kind).isAvailable else {
            errorMessage = AppKeePassCloudBrowserError.providerNotConfigured(kind).localizedDescription
            return
        }
        if kind == .googleDrive {
            await refreshGoogleDriveState()
            guard googleDriveState.isConnected else {
                errorMessage = AppKeePassCloudBrowserError.googleDriveNotConnected.localizedDescription
                return
            }
        }
        await reload()
    }

    func setFilter(_ newFilter: CloudFileBrowserFilter) async {
        guard filter != newFilter else {
            return
        }
        filter = newFilter
        directoryStack = []
        page = nil
        await reload()
    }

    func reload() async {
        guard let browser = browsers[selectedKind] else {
            errorMessage = AppKeePassCloudBrowserError.providerUnavailable(selectedKind).localizedDescription
            return
        }
        guard browser.availability.isAvailable else {
            errorMessage = AppKeePassCloudBrowserError.providerNotConfigured(selectedKind).localizedDescription
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            page = try await browser.browse(
                directoryID: currentDirectoryID,
                pageToken: nil,
                pageSize: CloudFileBrowserBrowserDefaults.pageSize,
                filter: filter
            )
            statusMessage = pageSummary()
        } catch {
            page = nil
            errorMessage = readableMessage(error)
        }
    }

    func openDirectory(_ entry: CloudFileBrowserEntry) async {
        guard entry.isDirectory else {
            errorMessage = AppKeePassCloudBrowserError.notADirectory(selectedKind).localizedDescription
            return
        }
        directoryStack.append(entry)
        page = nil
        await reload()
    }

    func goUp() async {
        guard !directoryStack.isEmpty else {
            return
        }
        directoryStack.removeLast()
        page = nil
        await reload()
    }

    func loadNextPage() async {
        guard let browser = browsers[selectedKind],
              let token = page?.nextPageToken else {
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let next = try await browser.browse(
                directoryID: currentDirectoryID,
                pageToken: token,
                pageSize: CloudFileBrowserBrowserDefaults.pageSize,
                filter: filter
            )
            let existing = page?.entries ?? []
            page = CloudFileBrowserPage(
                entries: existing + next.entries,
                nextPageToken: next.nextPageToken,
                totalCount: next.totalCount ?? page?.totalCount
            )
            statusMessage = pageSummary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openDatabase(_ entry: CloudFileBrowserEntry) async throws -> AppKeePassCloudOpenedFile {
        guard !entry.isDirectory else {
            throw AppKeePassCloudBrowserError.notADirectory(selectedKind)
        }
        guard entry.isKeePassDatabase else {
            throw AppKeePassCloudBrowserError.notAKeePassDatabase(selectedKind)
        }
        guard let provider = selectedKind.cloudFileProviderKind else {
            throw AppKeePassCloudBrowserError.providerUnavailable(selectedKind)
        }
        let browser = try requireBrowser()
        if selectedKind == .googleDrive {
            await refreshGoogleDriveState()
            guard googleDriveState.isConnected else {
                throw AppKeePassCloudBrowserError.googleDriveNotConnected
            }
        }
        if let previous = openedFile {
            previous.temporaryFile.removingFromDisk()
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let download = try await browser.download(entryID: entry.id)
        let temporaryFile = try temporaryDirectory.write(download.data, preferredName: entry.name)
        let marker = CloudFileVersionMarker(item: download.item)
        let opened = AppKeePassCloudOpenedFile(
            provider: provider,
            kind: selectedKind,
            entry: entry,
            download: download,
            marker: marker,
            temporaryFile: temporaryFile
        )
        openedFile = opened
        statusMessage = String(
            localized: "已下载 \(CloudFileKeePassFile.sanitizedName(entry.name)) 到受保护的临时位置，共 \(download.data.count) 字节"
        )
        return opened
    }

    /// 预览接管数据后立即删掉临时明文；临时文件只在下载到打开的这段窗口里存在。
    func completeOpening(_ opened: AppKeePassCloudOpenedFile) {
        opened.temporaryFile.removingFromDisk()
        if self.openedFile == opened {
            statusMessage = String(localized: "临时明文已清理")
        }
    }

    func latestMarker(for entry: CloudFileBrowserEntry) async throws -> CloudFileVersionMarker {
        let browser = try requireBrowser()
        let latest = try await browser.download(entryID: entry.id)
        return CloudFileVersionMarker(item: latest.item)
    }

    /// 保存前先拉最新版本比对 revision/ETag：发现别人改过就抛冲突，绝不覆盖。
    func save(
        _ data: Data,
        to opened: AppKeePassCloudOpenedFile
    ) async throws -> CloudFileBrowserWriteReceipt {
        guard selectedKind == opened.kind else {
            throw AppKeePassCloudBrowserError.providerUnavailable(selectedKind)
        }
        let browser = try requireBrowser()
        let latest = try await browser.download(entryID: opened.entry.id)
        let latestMarker = CloudFileVersionMarker(item: latest.item)
        guard !opened.marker.conflicts(with: latestMarker) else {
            throw AppKeePassCloudBrowserError.conflict(
                kind: opened.kind,
                fileName: CloudFileKeePassFile.sanitizedName(opened.entry.name),
                latestRevision: latestMarker.revision
            )
        }
        let receipt = try await browser.overwrite(
            entryID: opened.entry.id,
            data: data,
            expectedRevision: opened.marker.revision
        )
        statusMessage = String(
            localized: "已保存 \(CloudFileKeePassFile.sanitizedName(receipt.name)) 到 \(opened.kind.displayName)，共 \(receipt.byteCount) 字节"
        )
        return receipt
    }

    func saveCopy(
        _ data: Data,
        of opened: AppKeePassCloudOpenedFile,
        now: Date = Date()
    ) async throws -> CloudFileBrowserWriteReceipt {
        let browser = try requireBrowser()
        let name = AppKeePassCloudCopyName.make(baseName: opened.entry.name, now: now)
        let receipt = try await browser.upload(
            named: name,
            data: data,
            in: currentDirectoryID,
            expectedRevision: nil
        )
        statusMessage = String(
            localized: "已另存副本 \(CloudFileKeePassFile.sanitizedName(receipt.name))，共 \(receipt.byteCount) 字节"
        )
        return receipt
    }

    func cleanupTemporaryFiles() {
        if let openedFile {
            openedFile.temporaryFile.removingFromDisk()
        }
        temporaryDirectory.removeAll()
    }

    func refreshGoogleDriveState() async {
        guard let googleDriveAuthentication else {
            googleDriveState = .disconnected
            return
        }
        if let session = await googleDriveAuthentication.restoreSession() {
            googleDriveState = .connected(accountLabel: session.accountLabel)
        } else {
            googleDriveState = .disconnected
        }
    }

    func signInGoogleDrive() async {
        guard let googleDriveAuthentication else {
            googleDriveState = .failed(String(localized: "Google Drive 未配置。"))
            return
        }
        guard availability(for: .googleDrive).isAvailable else {
            googleDriveState = .failed(
                AppKeePassCloudBrowserError.providerNotConfigured(.googleDrive).localizedDescription
            )
            errorMessage = googleDriveState.label
            return
        }
        googleDriveState = .running
        do {
            let session = try await googleDriveAuthentication.signIn()
            googleDriveState = .connected(accountLabel: session.accountLabel)
            statusMessage = session.redactedSummary
        } catch {
            googleDriveState = .failed(readableMessage(error))
        }
    }

    func signOutGoogleDrive() async {
        guard let googleDriveAuthentication else {
            googleDriveState = .disconnected
            return
        }
        await googleDriveAuthentication.signOut()
        googleDriveState = .disconnected
        page = nil
        directoryStack = []
        statusMessage = String(localized: "已退出 Google Drive")
    }

    private func requireBrowser() throws -> any CloudFileBrowser {
        guard let browser = browsers[selectedKind] else {
            throw AppKeePassCloudBrowserError.providerUnavailable(selectedKind)
        }
        guard browser.availability.isAvailable else {
            throw AppKeePassCloudBrowserError.providerNotConfigured(selectedKind)
        }
        return browser
    }

    private func pageSummary() -> String {
        guard let page else {
            return ""
        }
        return String(
            localized: "\(selectedKind.displayName) 当前目录 \(page.directories.count) 个目录、\(page.keePassDatabases.count) 个 KeePass 数据库"
        )
    }

    private func readableMessage(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

extension AppKeePassCloudBrowserModel {
    static func production(environment: MonicaAppEnvironment) -> AppKeePassCloudBrowserModel {
        AppKeePassCloudBrowserModel(
            browsers: environment.productionCloudFileBrowsers,
            googleDriveAuthentication: environment.googleDriveAuthenticationService,
            temporaryDirectory: AppKeePassCloudTemporaryDirectory()
        )
    }
}
