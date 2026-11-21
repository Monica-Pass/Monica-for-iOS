//
//  MonicaSendShareView.swift
//  MonicaApp
//
//  Monica Send 端到端加密分享（#36）。
//
//  - 发送侧：解锁状态下把一条 Send 条目（文本或文件）封装成 `.send` 分享包。明文只存在于内存，
//    加密后写入 Application Support（`.completeFileProtection`、不参与备份、不进临时目录）。
//  - 分享码：32 字节令牌的 base64url，只在界面上显示一次；复制走统一的敏感剪贴板治理（定时清空），
//    不写日志、不落盘、不进 UserDefaults。
//  - 接收侧：导入 `.send` 文件 + 分享码，在本机解密；解密成功后立刻销毁本机分享包，
//    失败（含篡改、过期、次数用尽）不会写入账本，锁定态一律拒绝解密。
//  - 本机没有自建中继服务器：这里的「链接」= `monica://send/<id>#<code>` 本地凭据，
//    必须和 `.send` 文件一起交给对方，全程不经过任何服务器。
//

import Foundation
import MonicaStorage
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#endif

// MARK: - 本机存储

/// 分享包 / 临时导出文件 / 次数账本在本机的落盘位置。
///
/// 全部放在 Application Support 下的 `MonicaSend/`：不参与 iCloud 备份，
/// iOS 上用 `.completeFileProtection` 写入，锁屏后读取会被系统拒绝。
enum MonicaSendPackageStore {
    static let folderName = "MonicaSend"
    static let packagesFolderName = "packages"
    static let exportsFolderName = "exports"

    static var rootDirectory: URL {
        get throws {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let root = base.appendingPathComponent(folderName, isDirectory: true)
            try ensureDirectory(root)
            return root
        }
    }

    static func packagesDirectory() throws -> URL {
        try directory(named: packagesFolderName)
    }

    static func exportsDirectory() throws -> URL {
        try directory(named: exportsFolderName)
    }

    static func ledger() throws -> MonicaSendConsumptionLedger {
        MonicaSendConsumptionLedger(directoryURL: try rootDirectory)
    }

    static func packageFileName(for id: String) -> String {
        "\(id).\(MonicaSendPackage.fileExtension)"
    }

    /// 写入（或覆盖）某条 Send 的分享包。同一 Send 只保留最新的一份，旧分享码随之作废。
    static func writePackage(_ data: Data, id: String) throws -> URL {
        let url = try packagesDirectory().appendingPathComponent(packageFileName(for: id), isDirectory: false)
        try writeProtected(data, to: url)
        return url
    }

    /// 从外部（文件 App、AirDrop、其他 App）导入一份分享包，复制到本机工作目录。
    static func importPackage(from source: URL) throws -> URL {
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: source)
        _ = try MonicaSendPackage.inspect(data)
        let name = source.lastPathComponent.isEmpty
            ? "\(UUID().uuidString).\(MonicaSendPackage.fileExtension)"
            : source.lastPathComponent
        // 用随机前缀避免同名覆盖：同一份分享包可能被重复导入（例如重试）。
        let url = try packagesDirectory()
            .appendingPathComponent("inbox-\(UUID().uuidString)-\(name)", isDirectory: false)
        try writeProtected(data, to: url)
        return url
    }

    /// 为「已解密文件」写一份临时导出副本。调用方必须在离开页面时删除。
    static func exportFile(_ content: Data, fileName: String) throws -> URL {
        let url = try exportsDirectory()
            .appendingPathComponent("\(UUID().uuidString)-\(sanitizedFileName(fileName))", isDirectory: false)
        try writeProtected(content, to: url)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func removeExports() {
        guard let directory = try? exportsDirectory() else { return }
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in urls {
            try? fileManager.removeItem(at: url)
        }
    }

    /// 已生成、仍在本机的分享包（含元数据），按创建时间倒序。
    static func packageFiles() -> [(url: URL, descriptor: MonicaSendPackageDescriptor)] {
        guard let directory = try? packagesDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var result: [(url: URL, descriptor: MonicaSendPackageDescriptor)] = []
        for url in urls where url.pathExtension.lowercased() == MonicaSendPackage.fileExtension {
            guard let data = try? Data(contentsOf: url),
                  let descriptor = try? MonicaSendPackage.inspect(data) else {
                continue
            }
            result.append((url, descriptor))
        }
        return result.sorted { $0.descriptor.policy.createdAt > $1.descriptor.policy.createdAt }
    }

    /// 过期或次数用尽的分享包已经没有解密价值，直接销毁，避免占用空间。
    @discardableResult
    static func purgeUnusablePackages(
        ledger: MonicaSendConsumptionLedger,
        now: Date = Date()
    ) -> Int {
        let records = (try? ledger.allRecords()) ?? [:]
        var removed = 0
        for item in packageFiles() {
            let consumed = records[item.descriptor.ledgerKey]?.openCount ?? 0
            if item.descriptor.isExpired(at: now) || consumed >= item.descriptor.policy.maxViews {
                remove(item.url)
                removed += 1
            }
        }
        return removed
    }

    /// 同一条 Send 重新生成后，旧分享包的账本记录不再有意义（旧文件已被覆盖）。
    static func pruneLedger(
        _ ledger: MonicaSendConsumptionLedger,
        forPackageID packageID: String,
        keeping ledgerKey: String
    ) {
        guard let records = try? ledger.allRecords() else { return }
        let prefix = "\(packageID)@"
        for key in records.keys where key.hasPrefix(prefix) && key != ledgerKey {
            try? ledger.removeRecord(for: key)
        }
    }

    static func fileSize(of url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    private static func directory(named name: String) throws -> URL {
        let directory = try rootDirectory.appendingPathComponent(name, isDirectory: true)
        try ensureDirectory(directory)
        return directory
    }

    private static func ensureDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(values)
    }

    private static func writeProtected(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    private static func sanitizedFileName(_ fileName: String) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "monica-send"
        guard !trimmed.isEmpty else { return fallback }
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = trimmed
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .prefix(MonicaSendPackage.maximumFileNameLength)
        return cleaned.isEmpty ? fallback : String(cleaned)
    }
}

// MARK: - 接收入口

/// 从 URL scheme 或 `.send` 文件导入进入接收页的一次性状态。
struct MonicaSendIncoming: Identifiable, Equatable {
    let id = UUID()
    var packageURL: URL?
    var code: String?
    var failureMessage: String?
}

extension AppSessionModel {
    /// 处理 `monica://send/<id>#<code>` 与 `.send` 文件导入；返回是否已被 Monica Send 消费。
    ///
    /// 只记录入口，不在这里解密：锁定态必须等用户解锁后再由接收页走 `MonicaSendPackage.open`。
    @discardableResult
    func handleMonicaSendURL(_ url: URL) -> Bool {
        if let link = MonicaSendLink.parse(url) {
            monicaSendIncoming = MonicaSendIncoming(packageURL: nil, code: link.code.encoded)
            return true
        }
        guard url.isFileURL,
              url.pathExtension.lowercased() == MonicaSendPackage.fileExtension else {
            return false
        }
        do {
            let imported = try MonicaSendPackageStore.importPackage(from: url)
            monicaSendIncoming = MonicaSendIncoming(packageURL: imported, code: nil)
        } catch {
            monicaSendIncoming = MonicaSendIncoming(
                packageURL: nil,
                code: nil,
                failureMessage: error.localizedDescription
            )
        }
        return true
    }
}

// MARK: - 展示辅助

/// 本机已有分享包的展示快照。
struct MonicaSendPackageSnapshot: Identifiable, Equatable {
    let url: URL
    let descriptor: MonicaSendPackageDescriptor
    let byteCount: Int
    let consumedViews: Int

    var id: String { url.path }
    var fileName: String { url.lastPathComponent }
    var remainingViews: Int { descriptor.remainingViews(consumed: consumedViews) }
    var isExpired: Bool { descriptor.isExpired() }
    var isConsumed: Bool { remainingViews <= 0 }
    var isUsable: Bool { !isExpired && !isConsumed }
}

func monicaSendGroupedCode(_ code: String) -> String {
    var result = ""
    var index = 0
    for character in code {
        if index > 0 && index % 4 == 0 {
            result.append("-")
        }
        result.append(character)
        index += 1
    }
    return result
}

func monicaSendByteText(_ byteCount: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: Int64(byteCount))
}

func monicaSendTimestampText(_ date: Date) -> String {
    date.formatted(date: .numeric, time: .shortened)
}

// MARK: - 发送侧状态

@MainActor
@Observable
final class MonicaSendShareModel {
    struct FileDraft: Equatable {
        var fileName: String
        var mediaType: String
        var byteCount: Int
        var content: Data
    }

    struct Generated: Equatable {
        var packageURL: URL
        var fileName: String
        var byteCount: Int
        var code: String
        var link: String
        var createdAt: Date
        var expiresAt: Date?
        var maxViews: Int
    }

    let entry: LocalSendEntry
    var source: MonicaSendContentKind
    var fileDraft: FileDraft?
    var generated: Generated?
    var existing: [MonicaSendPackageSnapshot] = []
    var statusMessage: String?
    var errorMessage: String?
    var isWorking = false

    /// 分享包 id：优先复用 Send 条目 id（同一 Send 反复生成时落在同一个文件上）。
    let packageID: String

    init(entry: LocalSendEntry) {
        self.entry = entry
        self.source = entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .file : .text
        self.packageID = MonicaSendPackage.isValidIdentifier(entry.id) ? entry.id : UUID().uuidString
    }

    var maxViews: Int {
        min(max(entry.maxViews, 1), MonicaSendPackage.maximumViewCount)
    }

    /// 过期时间：空 = 不过期；无法识别 = 不过期 + 界面提示。
    var expiry: (date: Date?, warning: String?) {
        let text = entry.expiresAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, nil) }
        if let date = MonicaSendExpiry.date(from: text) {
            return (date, nil)
        }
        return (nil, String(localized: "过期时间无法识别，分享包不会自动过期。"))
    }

    var expiryText: String {
        entry.expiresAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "不过期")
            : entry.expiresAt
    }

    var textSummary: String {
        String(localized: "纯文本") + " · \(entry.body.count) " + String(localized: "字符")
    }

    var canGenerate: Bool {
        switch source {
        case .text:
            return !entry.body.isEmpty
        case .file:
            return fileDraft != nil
        }
    }

    func importFile(_ url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= MonicaSendPackage.maximumPayloadByteCount else {
            throw MonicaSendPackageError.payloadTooLarge(limit: MonicaSendPackage.maximumPayloadByteCount)
        }
        let content = try Data(contentsOf: url)
        guard content.count <= MonicaSendPackage.maximumPayloadByteCount else {
            throw MonicaSendPackageError.payloadTooLarge(limit: MonicaSendPackage.maximumPayloadByteCount)
        }
        let fileName = url.lastPathComponent.isEmpty ? "monica-send" : url.lastPathComponent
        let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        fileDraft = FileDraft(
            fileName: String(fileName.prefix(MonicaSendPackage.maximumFileNameLength)),
            mediaType: String(mediaType.prefix(MonicaSendPackage.maximumMediaTypeLength)),
            byteCount: content.count,
            content: content
        )
        // 换了文件就不再展示上一份分享包，避免“文件对不上”的误操作。
        generated = nil
        errorMessage = nil
    }

    /// 只在 Vault 解锁时调用：明文（文本正文或刚导入的文件字节）不会离开内存。
    func generate(isVaultUnlocked: Bool, now: Date = Date()) {
        errorMessage = nil
        statusMessage = nil
        guard isVaultUnlocked else {
            errorMessage = String(localized: "解锁 Vault 后才能封装分享包。")
            return
        }
        let content: Data
        var fileName = ""
        var mediaType = ""
        switch source {
        case .text:
            guard !entry.body.isEmpty else {
                errorMessage = String(localized: "内容为空，无法生成文本分享包。")
                return
            }
            content = Data(entry.body.utf8)
        case .file:
            guard let fileDraft else {
                errorMessage = String(localized: "请先选择要分享的文件。")
                return
            }
            content = fileDraft.content
            fileName = fileDraft.fileName
            mediaType = fileDraft.mediaType
        }
        guard content.count <= MonicaSendPackage.maximumPayloadByteCount else {
            errorMessage = String(localized: "内容超过 64 MiB，请改用其他方式分享。")
            return
        }

        let resolvedExpiry = expiry
        let policy = MonicaSendPolicy(
            id: packageID,
            kind: source,
            title: entry.title,
            fileName: fileName,
            mediaType: mediaType,
            createdAt: now,
            expiresAt: resolvedExpiry.date,
            maxViews: maxViews
        )
        isWorking = true
        defer { isWorking = false }
        do {
            let sealed = try MonicaSendPackage.seal(policy: policy, content: content, now: now)
            let url = try MonicaSendPackageStore.writePackage(sealed.data, id: packageID)
            let link = try sealed.makeLink()
            generated = Generated(
                packageURL: url,
                fileName: url.lastPathComponent,
                byteCount: sealed.data.count,
                code: sealed.code.encoded,
                link: link.absoluteString,
                createdAt: now,
                expiresAt: resolvedExpiry.date,
                maxViews: maxViews
            )
            if let warning = resolvedExpiry.warning {
                statusMessage = warning
            }
            if let ledger = try? MonicaSendPackageStore.ledger() {
                MonicaSendPackageStore.pruneLedger(
                    ledger,
                    forPackageID: packageID,
                    keeping: sealed.descriptor.ledgerKey
                )
            }
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 销毁本机分享包并撤销它的账本记录：同一台设备上重新导入副本也无法解密。
    func destroyGenerated() {
        guard let generated else { return }
        // 先读出账本键，再删文件。
        let descriptor = (try? Data(contentsOf: generated.packageURL))
            .flatMap { try? MonicaSendPackage.inspect($0) }
        MonicaSendPackageStore.remove(generated.packageURL)
        if let descriptor, let ledger = try? MonicaSendPackageStore.ledger() {
            try? ledger.registerRevocation(for: descriptor.ledgerKey)
        }
        self.generated = nil
        statusMessage = String(localized: "本机分享包已销毁。")
        refresh()
    }

    func destroy(_ snapshot: MonicaSendPackageSnapshot) {
        MonicaSendPackageStore.remove(snapshot.url)
        if let ledger = try? MonicaSendPackageStore.ledger() {
            try? ledger.registerRevocation(for: snapshot.descriptor.ledgerKey)
        }
        if generated?.packageURL == snapshot.url {
            generated = nil
        }
        statusMessage = String(localized: "本机分享包已销毁。")
        refresh()
    }

    func refresh() {
        guard let ledger = try? MonicaSendPackageStore.ledger() else {
            existing = []
            return
        }
        MonicaSendPackageStore.purgeUnusablePackages(ledger: ledger)
        let records = (try? ledger.allRecords()) ?? [:]
        existing = MonicaSendPackageStore.packageFiles()
            .filter { $0.descriptor.policy.id == packageID }
            .map { item in
                MonicaSendPackageSnapshot(
                    url: item.url,
                    descriptor: item.descriptor,
                    byteCount: MonicaSendPackageStore.fileSize(of: item.url),
                    consumedViews: records[item.descriptor.ledgerKey]?.openCount ?? 0
                )
            }
    }
}

// MARK: - 接收侧状态

@MainActor
@Observable
final class MonicaSendReceiveModel {
    var packageURL: URL?
    var descriptor: MonicaSendPackageDescriptor?
    var codeInput = ""
    var openedText: String?
    var exportedFileURL: URL?
    var exportedFileName: String?
    var remainingViews: Int?
    var statusMessage: String?
    var errorMessage: String?
    var isWorking = false
    var packageWasDestroyed = false

    var packageFileName: String {
        packageURL?.lastPathComponent ?? ""
    }

    var packageByteCount: Int {
        guard let packageURL else { return 0 }
        return MonicaSendPackageStore.fileSize(of: packageURL)
    }

    var canOpen: Bool {
        packageURL != nil && !codeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func attach(packageURL: URL?, code: String?, failureMessage: String?) {
        if let packageURL {
            self.packageURL = packageURL
            self.descriptor = (try? Data(contentsOf: packageURL)).flatMap { try? MonicaSendPackage.inspect($0) }
        }
        if let code {
            codeInput = code
        }
        errorMessage = failureMessage
    }

    /// 选择本机文件（.send）。
    func selectPackage(at url: URL) {
        do {
            let imported = try MonicaSendPackageStore.importPackage(from: url)
            packageURL = imported
            descriptor = (try? Data(contentsOf: imported)).flatMap { try? MonicaSendPackage.inspect($0) }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(isVaultUnlocked: Bool, now: Date = Date()) {
        guard let packageURL else {
            errorMessage = String(localized: "请先选择 .send 分享包。")
            return
        }
        guard isVaultUnlocked else {
            errorMessage = String(localized: "Vault 已锁定，解锁后才能解密分享包。")
            return
        }
        let code: MonicaSendCode
        do {
            code = try MonicaSendCode.parse(codeInput)
        } catch {
            errorMessage = String(localized: "分享码无效，请核对后重试。")
            return
        }
        errorMessage = nil
        statusMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try Data(contentsOf: packageURL)
            let ledger = try MonicaSendPackageStore.ledger()
            let opened = try MonicaSendPackage.open(
                data,
                code: code,
                ledger: ledger,
                now: now,
                isVaultLocked: false
            )
            descriptor = opened.descriptor
            remainingViews = opened.remainingViews
            if let text = opened.text, opened.descriptor.policy.kind == .text {
                openedText = text
                exportedFileURL = nil
                exportedFileName = nil
            } else {
                let name = opened.descriptor.policy.fileName.isEmpty
                    ? "monica-send-\(opened.descriptor.policy.id)"
                    : opened.descriptor.policy.fileName
                let url = try MonicaSendPackageStore.exportFile(opened.content, fileName: name)
                exportedFileURL = url
                exportedFileName = url.lastPathComponent
                openedText = nil
            }
            // 解密成功就立刻销毁载荷：分享包文件不再有任何用处。
            destroyPayload()
            packageWasDestroyed = true
            statusMessage = opened.remainingViews > 0
                ? String(localized: "已消耗 1 次查看，分享包仍可继续使用。")
                : String(localized: "这是最后一次查看，分享包已失效。")
        } catch let error as MonicaSendPackageError {
            errorMessage = error.localizedDescription
            switch error {
            case .expired, .viewLimitReached:
                destroyPayload()
                packageWasDestroyed = true
                statusMessage = String(localized: "该分享包已失效，本机副本已销毁。")
            default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cleanup() {
        if let exportedFileURL {
            MonicaSendPackageStore.remove(exportedFileURL)
        }
        exportedFileURL = nil
        openedText = nil
        codeInput = ""
        MonicaSendPackageStore.removeExports()
    }

    private func destroyPayload() {
        guard let packageURL else { return }
        MonicaSendPackageStore.remove(packageURL)
        self.packageURL = nil
    }
}

// MARK: - 发送侧界面

/// 详情页里的「加密分享」入口。
struct MonicaSendShareSection: View {
    @Bindable var session: AppSessionModel
    let entry: LocalSendEntry

    @State private var isSharePresented = false
    @State private var snapshots: [MonicaSendPackageSnapshot] = []

    var body: some View {
        AndroidParitySection(title: String(localized: "加密分享")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                Text("把这条 Send 封装成端到端加密的 .send 分享包。Monica 没有云端中继，分享包和一次性分享码需要分开交给对方。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let snapshot = snapshots.first {
                    AndroidParityInfoRow(title: String(localized: "本机分享包"), value: snapshot.fileName)
                    AndroidParityInfoRow(title: String(localized: "剩余查看次数"), value: String(snapshot.remainingViews))
                    AndroidParityInfoRow(title: String(localized: "创建时间"), value: monicaSendTimestampText(snapshot.descriptor.policy.createdAt))
                } else {
                    AndroidParityInfoRow(title: String(localized: "本机分享包"), value: String(localized: "尚未生成"))
                }
                Button {
                    isSharePresented = true
                } label: {
                    Label(
                        snapshots.isEmpty ? String(localized: "生成加密分享包") : String(localized: "管理加密分享"),
                        systemImage: "lock.doc"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                .disabled(session.vaultState != .unlocked)
                if session.vaultState != .unlocked {
                    Text("解锁 Vault 后才能封装分享包。")
                        .font(.caption2)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
            }
        }
        .task {
            refresh()
        }
        .sheet(isPresented: $isSharePresented, onDismiss: refresh) {
            MonicaSendShareSheet(session: session, entry: entry)
        }
    }

    private func refresh() {
        guard let ledger = try? MonicaSendPackageStore.ledger() else {
            snapshots = []
            return
        }
        MonicaSendPackageStore.purgeUnusablePackages(ledger: ledger)
        let records = (try? ledger.allRecords()) ?? [:]
        snapshots = MonicaSendPackageStore.packageFiles()
            .filter { $0.descriptor.policy.id == entry.id }
            .map { item in
                MonicaSendPackageSnapshot(
                    url: item.url,
                    descriptor: item.descriptor,
                    byteCount: MonicaSendPackageStore.fileSize(of: item.url),
                    consumedViews: records[item.descriptor.ledgerKey]?.openCount ?? 0
                )
            }
    }
}

struct MonicaSendShareSheet: View {
    @Bindable var session: AppSessionModel
    let entry: LocalSendEntry

    @Environment(\.dismiss) private var dismiss
    @State private var model: MonicaSendShareModel
    @State private var isFileImporterPresented = false
    @State private var copyMessage: String?

    init(session: AppSessionModel, entry: LocalSendEntry) {
        self.session = session
        self.entry = entry
        _model = State(initialValue: MonicaSendShareModel(entry: entry))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                noticeCard
                if session.vaultState == .unlocked {
                    sourceSection
                    policySection
                    generateSection
                    if let generated = model.generated {
                        generatedSection(generated)
                    }
                    if !otherSnapshots.isEmpty {
                        packageSection
                    }
                } else {
                    lockedCard
                }
                if let status = model.statusMessage {
                    messageRow(status, color: AndroidParityPalette.primary)
                }
                if let error = model.errorMessage {
                    messageRow(error, color: .red)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 60)
        }
        .background(AndroidParityPalette.background.ignoresSafeArea())
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard case .success(let urls) = result, let url = urls.first else { return }
                try model.importFile(url)
                model.errorMessage = nil
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
        .task {
            model.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.heavy))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AndroidParityPalette.textPrimary)
            Text("加密分享")
                .font(.title3.weight(.heavy))
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .lineLimit(2)
            Spacer()
            AndroidParityIconTile(systemImage: "lock.doc", fill: AndroidParityPalette.primaryContainer)
        }
    }

    private var noticeCard: some View {
        AndroidParityCard(fill: AndroidParityPalette.primaryContainer) {
            Label("端到端加密", systemImage: "lock.shield")
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(AndroidParityPalette.onPrimaryDeep)
            Text("明文只在内存中加密，.send 文件里没有可读内容。分享码不会保存，关闭本页后需要重新生成。")
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.onPrimaryDeep.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lockedCard: some View {
        AndroidParityCard {
            Label("已锁定", systemImage: "lock.fill")
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(AndroidParityPalette.textPrimary)
            Text("解锁 Vault 后才能读取这条 Send 并封装分享包。")
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
    }

    private var sourceSection: some View {
        AndroidParitySection(title: String(localized: "分享内容")) {
            AndroidParityCard(fill: AndroidParityPalette.surface.opacity(0.92)) {
                Picker(String(localized: "分享类型"), selection: Bindable(model).source) {
                    ForEach(MonicaSendContentKind.allCases, id: \.self) { kind in
                        Text(kind.localizedName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                switch model.source {
                case .text:
                    AndroidParityInfoRow(title: String(localized: "标题"), value: entry.title)
                    AndroidParityInfoRow(title: String(localized: "内容"), value: model.textSummary)
                    if entry.body.isEmpty {
                        Text("内容为空，无法生成文本分享包。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                case .file:
                    if let draft = model.fileDraft {
                        AndroidParityInfoRow(title: String(localized: "文件名"), value: draft.fileName)
                        AndroidParityInfoRow(title: String(localized: "大小"), value: monicaSendByteText(draft.byteCount))
                    } else {
                        AndroidParityInfoRow(title: String(localized: "文件名"), value: String(localized: "尚未选择"))
                    }
                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label(
                            model.fileDraft == nil ? String(localized: "选择文件") : String(localized: "更换文件"),
                            systemImage: "paperclip"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                }
            }
        }
    }

    private var policySection: some View {
        AndroidParitySection(title: String(localized: "分享策略")) {
            AndroidParityCard(fill: AndroidParityPalette.surface.opacity(0.92)) {
                AndroidParityInfoRow(title: String(localized: "过期时间"), value: model.expiryText)
                AndroidParityInfoRow(title: String(localized: "最多查看次数"), value: String(model.maxViews))
                Text("接收方每次成功解密消耗一次，次数用尽或过期后自动失效；失败不会扣次数。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning = model.expiry.warning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var generateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.generate(isVaultUnlocked: session.vaultState == .unlocked)
            } label: {
                Label(
                    model.generated == nil ? String(localized: "生成加密分享包") : String(localized: "重新生成分享包"),
                    systemImage: "lock.badge.clock"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .filled))
            .disabled(model.isWorking || !model.canGenerate)
            Text("重新生成会覆盖本机旧的 .send 文件，旧分享码随之作废。")
                .font(.caption2)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
    }

    private func generatedSection(_ generated: MonicaSendShareModel.Generated) -> some View {
        AndroidParitySection(title: String(localized: "分享包")) {
            AndroidParityCard(fill: AndroidParityPalette.surface.opacity(0.92)) {
                AndroidParityInfoRow(title: String(localized: "文件名"), value: generated.fileName)
                AndroidParityInfoRow(title: String(localized: "大小"), value: monicaSendByteText(generated.byteCount))
                AndroidParityInfoRow(
                    title: String(localized: "过期时间"),
                    value: generated.expiresAt.map(monicaSendTimestampText) ?? String(localized: "不过期")
                )
                AndroidParityInfoRow(title: String(localized: "最多查看次数"), value: String(generated.maxViews))
                AndroidParityDivider()
                Text("一次性分享码")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(AndroidParityPalette.primary)
                Text(verbatim: monicaSendGroupedCode(generated.code))
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        AndroidParityPalette.surfaceVariant,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                Text("分享码只显示这一次，等同于解密钥匙。请和 .send 文件分开传递，不要一起发在同一条消息里。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        copy(generated.code)
                    } label: {
                        Label("复制分享码", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    Button {
                        copy(generated.link)
                    } label: {
                        Label("复制链接", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                }
                if let copyMessage {
                    Text(copyMessage)
                        .font(.caption2)
                        .foregroundStyle(AndroidParityPalette.primary)
                }
                ShareLink(
                    item: generated.packageURL,
                    preview: SharePreview(
                        String(localized: "Monica Send 加密分享包"),
                        image: Image(systemName: "lock.doc")
                    )
                ) {
                    Label("分享 .send 文件", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                Text(verbatim: generated.link)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("链接只在本机有效：它指向这条分享包的本地标识，需要和 .send 文件一起使用。")
                    .font(.caption2)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(role: .destructive) {
                    model.destroyGenerated()
                } label: {
                    Label("销毁本机分享包", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
            }
        }
    }

    private var packageSection: some View {
        AndroidParitySection(title: String(localized: "本机分享包")) {
            AndroidParityCard(fill: AndroidParityPalette.surface.opacity(0.92)) {
                ForEach(otherSnapshots) { snapshot in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(snapshot.fileName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text(snapshotStatus(snapshot))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(snapshot.isUsable ? AndroidParityPalette.primary : AndroidParityPalette.textSecondary)
                        }
                        Text(monicaSendByteText(snapshot.byteCount))
                            .font(.caption2)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                        HStack(spacing: 10) {
                            Button(role: .destructive) {
                                model.destroy(snapshot)
                            } label: {
                                Label("销毁", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
                        }
                    }
                    if snapshot.id != otherSnapshots.last?.id {
                        AndroidParityDivider()
                    }
                }
            }
        }
    }

    /// 已经展示在上方「分享包」卡片里的那一份不重复列出。
    private var otherSnapshots: [MonicaSendPackageSnapshot] {
        guard let generatedURL = model.generated?.packageURL else { return model.existing }
        return model.existing.filter { $0.url != generatedURL }
    }

    private func snapshotStatus(_ snapshot: MonicaSendPackageSnapshot) -> String {
        if snapshot.isExpired {
            return String(localized: "已过期")
        }
        if snapshot.isConsumed {
            return String(localized: "已消耗")
        }
        return String(localized: "剩余") + " \(snapshot.remainingViews) " + String(localized: "次")
    }

    private func copy(_ value: String) {
        copyMessage = session.copySensitiveValueToPasteboard(value).message
    }

    private func messageRow(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 接收侧界面

struct MonicaSendReceiveSheet: View {
    @Bindable var session: AppSessionModel
    let incoming: MonicaSendIncoming

    @Environment(\.dismiss) private var dismiss
    @State private var model = MonicaSendReceiveModel()
    @State private var isFileImporterPresented = false
    @State private var copyMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                noticeCard
                packageSection
                if let descriptor = model.descriptor {
                    metadataSection(descriptor)
                }
                codeSection
                openSection
                if let text = model.openedText {
                    openedTextSection(text)
                }
                if let url = model.exportedFileURL {
                    openedFileSection(url)
                }
                if let status = model.statusMessage {
                    messageRow(status, color: AndroidParityPalette.primary)
                }
                if let error = model.errorMessage {
                    messageRow(error, color: .red)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 60)
        }
        .background(AndroidParityPalette.background.ignoresSafeArea())
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            model.selectPackage(at: url)
        }
        .task {
            model.attach(
                packageURL: incoming.packageURL,
                code: incoming.code,
                failureMessage: incoming.failureMessage
            )
        }
        .onDisappear {
            model.cleanup()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.heavy))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AndroidParityPalette.textPrimary)
            Text("打开分享包")
                .font(.title3.weight(.heavy))
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .lineLimit(2)
            Spacer()
            AndroidParityIconTile(systemImage: "lock.open", fill: AndroidParityPalette.primaryContainer)
        }
    }

    private var noticeCard: some View {
        AndroidParityCard(fill: AndroidParityPalette.primaryContainer) {
            Label("本机解密", systemImage: "lock.shield")
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(AndroidParityPalette.onPrimaryDeep)
            Text("分享包内容只在这台设备上解密，不会上传。解密成功后本机分享包会被立刻销毁。")
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.onPrimaryDeep.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var packageSection: some View {
        AndroidParitySection(title: String(localized: "分享包")) {
            AndroidParityCard(fill: AndroidParityPalette.surface.opacity(0.92)) {
                if model.packageURL != nil {
                    AndroidParityInfoRow(title: String(localized: "文件名"), value: model.packageFileName)
                    AndroidParityInfoRow(title: String(localized: "大小"), value: monicaSendByteText(model.packageByteCount))
                } else if model.packageWasDestroyed {
                    AndroidParityInfoRow(title: String(localized: "状态"), value: String(localized: "已销毁"))
                } else {
                    AndroidParityInfoRow(title: String(localized: "文件名"), value: String(localized: "尚未选择"))
                }
                Button {
                    isFileImporterPresented = true
                } label: {
                    Label(
                        model.packageURL == nil ? String(localized: "选择 .send 文件") : String(localized: "更换分享包"),
                        systemImage: "doc.badge.plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                .disabled(model.openedText != nil || model.exportedFileURL != nil)
            }
        }
    }

    private func metadataSection(_ descriptor: MonicaSendPackageDescriptor) -> some View {
        AndroidParitySection(title: String(localized: "分享包信息")) {
            AndroidParityCard(fill: AndroidParityPalette.surface.opacity(0.92)) {
                AndroidParityInfoRow(title: String(localized: "标题"), value: descriptor.policy.title)
                AndroidParityInfoRow(title: String(localized: "类型"), value: descriptor.policy.kind.localizedName)
                if !descriptor.policy.fileName.isEmpty {
                    AndroidParityInfoRow(title: String(localized: "原始文件名"), value: descriptor.policy.fileName)
                }
                AndroidParityInfoRow(
                    title: String(localized: "过期时间"),
                    value: descriptor.policy.expiresAt.map(monicaSendTimestampText) ?? String(localized: "不过期")
                )
                AndroidParityInfoRow(title: String(localized: "最多查看次数"), value: String(descriptor.policy.maxViews))
                if let remainingViews = model.remainingViews {
                    AndroidParityInfoRow(title: String(localized: "剩余查看次数"), value: String(remainingViews))
                }
            }
        }
    }

    private var codeSection: some View {
        AndroidParitySection(title: String(localized: "分享码")) {
            AndroidParityCard(fill: AndroidParityPalette.surface.opacity(0.92)) {
                TextField(
                    String(localized: "粘贴分享码或 monica://send 链接"),
                    text: Bindable(model).codeInput
                )
                .font(.system(.callout, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(AndroidParityTextFieldStyle())
                .disabled(model.openedText != nil || model.exportedFileURL != nil)
                HStack(spacing: 10) {
                    Button {
                        paste()
                    } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(model.openedText != nil || model.exportedFileURL != nil)
                }
                Text("分享码来自发送方，应与 .send 文件分开传递；每一项分享包只对应一个分享码。")
                    .font(.caption2)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var openSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.open(isVaultUnlocked: session.vaultState == .unlocked)
            } label: {
                Label(
                    model.isWorking ? String(localized: "解密中") : String(localized: "解密并查看"),
                    systemImage: "lock.open"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .filled))
            .disabled(
                !model.canOpen
                    || model.isWorking
                    || session.vaultState != .unlocked
                    || model.openedText != nil
                    || model.exportedFileURL != nil
            )
            if session.vaultState != .unlocked {
                Text("Vault 已锁定，解锁后才能解密。")
                    .font(.caption2)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    private func openedTextSection(_ text: String) -> some View {
        AndroidParitySection(title: String(localized: "已解密内容")) {
            AndroidParityCard(fill: AndroidParityPalette.surface.opacity(0.92)) {
                Text(verbatim: text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    copy(text)
                } label: {
                    Label("复制内容", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                if let copyMessage {
                    Text(copyMessage)
                        .font(.caption2)
                        .foregroundStyle(AndroidParityPalette.primary)
                }
                Text("分享包已在本机销毁，内容只保留在当前页面；离开页面后不会再有副本。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func openedFileSection(_ url: URL) -> some View {
        AndroidParitySection(title: String(localized: "已解密文件")) {
            AndroidParityCard(fill: AndroidParityPalette.surface.opacity(0.92)) {
                AndroidParityInfoRow(title: String(localized: "文件名"), value: model.exportedFileName ?? "")
                AndroidParityInfoRow(title: String(localized: "大小"), value: monicaSendByteText(MonicaSendPackageStore.fileSize(of: url)))
                ShareLink(
                    item: url,
                    preview: SharePreview(
                        model.exportedFileName ?? String(localized: "Monica Send 分享内容"),
                        image: Image(systemName: "doc")
                    )
                ) {
                    Label("导出到「文件」或其他 App", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                Text("为导出写出的临时解密副本会在关闭本页时删除，请尽快保存到目标位置。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func copy(_ value: String) {
        copyMessage = session.copySensitiveValueToPasteboard(value).message
    }

    private func paste() {
        #if os(iOS)
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        model.codeInput = text
        #endif
    }

    private func messageRow(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)
    }
}
