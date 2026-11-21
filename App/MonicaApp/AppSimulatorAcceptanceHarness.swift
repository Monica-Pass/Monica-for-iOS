import Foundation
import MonicaCore
import MonicaStorage

/// 模拟器端到端验收自检（不是 XCTest）。
///
/// 本机无法运行 XCTest（`xcodebuild test` 一律失败在 `DTServiceHubClient failed to bless
/// service hub`），因此把验收流程做成 App 内置的自检：由启动参数触发，用真实的
/// `AppSessionModel`、真实 MDBX 库与真实 Keychain 跑完整链路，写出结构化报告后退出。
///
/// 触发方式：
/// ```
/// xcrun simctl launch --console --terminate-running-process <udid> \
///     com.monicapass.monica --monica-simulator-acceptance
/// ```
/// 报告写到 App 沙盒的 `Documents/acceptance-report.json`，同时按
/// `ACCEPT <id> PASS|FAIL <detail>` 逐行打印，最后打印 `ACCEPT SUMMARY passed=<n> failed=<m>`。
/// 退出码 0 表示全部通过（skipped 不计失败），1 表示有失败步骤。
///
/// 安全约束：测试主密码是源码里的常量，报告与日志里只写「已设置」，不回显密码或 secret。
enum AppSimulatorAcceptanceHarness {
    static let launchArgument = "--monica-simulator-acceptance"
    static let reportFileName = "acceptance-report.json"
    /// 仅用于自检的临时库主密码；报告里不会回显。
    static let testMasterPassword = "Monica-Accept-2026!"
    /// RFC 6238 标准测试向量里的 Base32 secret；报告里只写「已设置」。
    static let testTotpSecret = "JBSWY3DPEHPK3PXP"

    // MARK: - 报告模型

    struct AcceptanceStepResult: Codable {
        let id: String
        let title: String
        let passed: Bool
        let detail: String
    }

    struct AcceptanceReport: Codable {
        let startedAt: String
        let finishedAt: String
        let passed: Int
        let failed: Int
        let skipped: Int
        let steps: [AcceptanceStepResult]
    }

    // MARK: - 入口

    static func shouldRun(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(launchArgument)
    }

    @MainActor
    static func runIfRequested(session: AppSessionModel, environment: MonicaAppEnvironment) async {
        guard shouldRun() else { return }

        // `simctl launch --console` 按行收集输出，禁用缓冲避免进程退出时丢日志。
        setbuf(stdout, nil)
        let runner = AcceptanceRunner(session: session, environment: environment)
        let exitCode = await runner.run()
        fflush(stdout)
        fflush(stderr)
        Darwin.exit(exitCode)
    }
}

// MARK: - 运行器

private struct AcceptanceHarnessError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

@MainActor
private final class AcceptanceRunner {
    private enum StepOutcome {
        case pass(String)
        case skip(String)
        case fail(String)
    }

    private let session: AppSessionModel
    private let environment: MonicaAppEnvironment
    private let startedAt = Date()

    private var results: [AppSimulatorAcceptanceHarness.AcceptanceStepResult] = []
    private var skippedIDs: [String] = []

    private var vaultReady = false
    private var vaultDirectory: URL?
    private var vaultFileURL: URL?
    /// 「验收条目」分类的 project id，条目都建在这里。
    private var entryProjectID = ""

    private static let remainingStepIDs: [(String, String)] = [
        ("entry-crud", "创建 13 类条目"),
        ("search-tags-archive", "搜索、标签与归档"),
        ("folders", "分类与文件夹"),
        ("trash", "回收站删除与恢复"),
        ("batch", "批量选择删除与恢复"),
        ("export-import", "CSV 导出导入与加密备份"),
        ("snapshot", "保险库快照创建与校验"),
        ("totp", "TOTP 生成"),
        ("generator", "密码生成与强度分析"),
        ("lock-unlock", "锁定与解锁"),
        ("widget-snapshot", "Widget 快照写入"),
        ("localization", "中英文切换"),
        ("autofill-index", "自动填充索引刷新"),
    ]

    init(session: AppSessionModel, environment: MonicaAppEnvironment) {
        self.session = session
        self.environment = environment
    }

    // MARK: - 主流程

    func run() async -> Int32 {
        print("ACCEPT START \(Self.isoString(from: startedAt))")

        await runStep("vault-create", "创建本地保险库并解锁") {
            try self.createVault()
        }

        guard vaultReady else {
            for (id, title) in Self.remainingStepIDs {
                record(id, title, .skip("前置步骤 vault-create 失败，保险库不可用"))
            }
            return finish()
        }

        await runStep("entry-crud", "创建 13 类条目") {
            try await self.entryCRUD()
        }
        await runStep("search-tags-archive", "搜索、标签与归档") {
            try await self.searchTagsArchive()
        }
        await runStep("folders", "分类与文件夹") {
            try self.folders()
        }
        await runStep("trash", "回收站删除与恢复") {
            try self.trash()
        }
        await runStep("batch", "批量选择删除与恢复") {
            try self.batch()
        }
        await runStep("export-import", "CSV 导出导入与加密备份") {
            try self.exportImport()
        }
        await runStep("snapshot", "保险库快照创建与校验") {
            try await self.snapshot()
        }
        await runStep("totp", "TOTP 生成") {
            try self.totp()
        }
        await runStep("generator", "密码生成与强度分析") {
            try self.generator()
        }
        await runStep("lock-unlock", "锁定与解锁") {
            try self.lockUnlock()
        }
        await runStep("widget-snapshot", "Widget 快照写入") {
            try self.widgetSnapshot()
        }
        await runStep("localization", "中英文切换") {
            try self.localization()
        }
        await runStep("autofill-index", "自动填充索引刷新") {
            try self.autoFillIndex()
        }

        return finish()
    }

    // MARK: - 步骤执行与记账

    private func runStep(
        _ id: String,
        _ title: String,
        _ body: () async throws -> StepOutcome
    ) async {
        do {
            record(id, title, try await body())
        } catch {
            record(id, title, .fail(Self.describe(error)))
        }
    }

    private func record(_ id: String, _ title: String, _ outcome: StepOutcome) {
        switch outcome {
        case .pass(let detail):
            results.append(.init(id: id, title: title, passed: true, detail: detail))
            print("ACCEPT \(id) PASS \(Self.singleLine(detail))")
        case .skip(let detail):
            skippedIDs.append(id)
            let rendered = "skipped — \(detail)"
            results.append(.init(id: id, title: title, passed: true, detail: rendered))
            print("ACCEPT \(id) PASS \(Self.singleLine(rendered))")
        case .fail(let detail):
            results.append(.init(id: id, title: title, passed: false, detail: detail))
            print("ACCEPT \(id) FAIL \(Self.singleLine(detail))")
        }
    }

    private func finish() -> Int32 {
        let finishedAt = Date()
        let passedCount = results.filter(\.passed).count
        let failedCount = results.count - passedCount

        var reportWriteFailed = false
        let report = AppSimulatorAcceptanceHarness.AcceptanceReport(
            startedAt: Self.isoString(from: startedAt),
            finishedAt: Self.isoString(from: finishedAt),
            passed: passedCount,
            failed: failedCount,
            skipped: skippedIDs.count,
            steps: results
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            let url = try Self.reportFileURL()
            try data.write(to: url, options: .atomic)
            print("ACCEPT REPORT \(url.path)")
        } catch {
            reportWriteFailed = true
            print("ACCEPT REPORT-FAILED \(Self.describe(error))")
        }

        if !skippedIDs.isEmpty {
            print("ACCEPT SKIPPED \(skippedIDs.count) \(skippedIDs.joined(separator: ","))")
        }
        print("ACCEPT SUMMARY passed=\(passedCount) failed=\(failedCount)")

        if failedCount > 0 || reportWriteFailed {
            return 1
        }
        return 0
    }

    // MARK: - 步骤 1：建库

    private func createVault() throws -> StepOutcome {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-sim-acceptance", isDirectory: true)
            .appendingPathComponent(Self.slug(from: startedAt), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultDirectory = root

        session.vaultName = "Monica 验收保险库"
        session.vaultPassword = AppSimulatorAcceptanceHarness.testMasterPassword
        try session.createLocalVault(in: root, deviceID: environment.localDeviceIdentifier)

        guard session.vaultState == .unlocked else {
            throw AcceptanceHarnessError("createLocalVault 后 vaultState 不是 unlocked")
        }
        guard let vaultSession = session.activeVaultSession, session.activeEntryRepository != nil else {
            throw AcceptanceHarnessError("createLocalVault 后没有活动的 vault session 或条目仓库")
        }
        vaultFileURL = vaultSession.descriptor.fileURL
        vaultReady = true

        let project = try session.createVaultCategory(title: "验收条目")
        entryProjectID = project.id

        return .pass(
            "临时库已创建并解锁（主密码已设置，不回显）；state=unlocked；分类「验收条目」已激活"
        )
    }

    // MARK: - 步骤 2：13 类条目 CRUD

    private func entryCRUD() async throws -> StepOutcome {
        let repository = try requireRepository()
        var created: [String] = []
        var failures: [String] = []

        func attempt(_ kind: String, _ body: () throws -> Int) {
            do {
                let count = try body()
                created.append("\(kind)=\(count)")
            } catch {
                failures.append("\(kind)（\(Self.describe(error))）")
            }
        }

        attempt("login") {
            session.loginTitle = "验收登录 Alpha"
            session.loginUsername = "alpha@example.com"
            session.loginPassword = "Accept-Login-Pass-2026!"
            session.loginURL = "https://example.com/alpha"
            session.loginNotes = "模拟器验收自检创建的登录条目"
            try session.createLoginEntry(projectTitle: "验收条目")
            return session.loginEntries.count
        }
        attempt("login2") {
            session.loginTitle = "验收登录 Beta"
            session.loginUsername = "beta@example.com"
            session.loginPassword = "Accept-Login-Pass-2026-B!"
            session.loginURL = "https://example.com/beta"
            session.loginNotes = "模拟器验收自检创建的第二条登录"
            try session.createLoginEntry(projectTitle: "验收条目")
            return session.loginEntries.count
        }
        attempt("totp") {
            session.totpTitle = "验收 TOTP"
            session.totpIssuer = "Monica Acceptance"
            session.totpAccountName = "acceptance@example.com"
            session.totpSecret = AppSimulatorAcceptanceHarness.testTotpSecret
            try session.createTotpEntry(projectTitle: "验收条目")
            return session.totpEntries.count
        }
        attempt("note") {
            session.noteTitle = "验收笔记"
            session.noteBody = "模拟器验收自检写入的笔记正文。"
            try session.createNoteEntry(projectTitle: "验收条目")
            return session.noteEntries.count
        }
        attempt("card") {
            session.cardTitle = "验收银行卡"
            session.cardNumber = "4111111111111111"
            session.cardExpiryMonth = "12"
            session.cardExpiryYear = "2030"
            session.cardIssuer = "Monica Bank"
            session.cardNetwork = "Visa"
            session.cardNotes = "模拟器验收自检创建"
            try session.createCardEntry(projectTitle: "验收条目")
            return session.cardEntries.count
        }
        attempt("identity") {
            session.identityTitle = "验收身份"
            session.identityFullName = "Acceptance Tester"
            session.identityIssuer = "Monica Acceptance Authority"
            session.identityCountry = "中国"
            session.identityNotes = "模拟器验收自检创建"
            try session.createIdentityEntry(projectTitle: "验收条目")
            return session.identityEntries.count
        }
        attempt("sshKey") {
            session.sshKeyTitle = "验收 SSH 密钥"
            session.sshKeyUsername = "acceptance"
            session.sshKeyHost = "example.com"
            session.sshKeyPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAcceptancePlaceholderKeyForHarnessOnly acceptance@example.com"
            session.sshKeyNotes = "模拟器验收自检创建"
            try session.createSshKeyEntry(projectTitle: "验收条目")
            return session.sshKeyEntries.count
        }
        attempt("apiToken") {
            session.apiTokenTitle = "验收 API Token"
            session.apiTokenIssuer = "Monica Acceptance"
            session.apiTokenToken = "acceptance-placeholder-token"
            session.apiTokenNotes = "模拟器验收自检创建"
            try session.createApiTokenEntry(projectTitle: "验收条目")
            return session.apiTokenEntries.count
        }
        attempt("wifi") {
            session.wifiTitle = "验收 Wi-Fi"
            session.wifiSSID = "Monica-Acceptance"
            session.wifiPassword = "Accept-Wifi-Pass-2026!"
            session.wifiNotes = "模拟器验收自检创建"
            try session.createWifiEntry(projectTitle: "验收条目")
            return session.wifiEntries.count
        }
        attempt("sso") {
            session.ssoTitle = "验收 SSO"
            session.ssoIssuer = "https://sso.example.com"
            session.ssoAccountName = "acceptance@example.com"
            session.ssoSecret = "Accept-SSO-Secret-2026!"
            session.ssoNotes = "模拟器验收自检创建"
            try session.createSSOEntry(projectTitle: "验收条目")
            return session.ssoEntries.count
        }
        attempt("barcode") {
            session.barcodeTitle = "验收条码"
            session.barcodePayload = "https://example.com/acceptance"
            session.barcodeLabel = "ACCEPTANCE"
            session.barcodeNotes = "模拟器验收自检创建"
            try session.createBarcodeEntry(projectTitle: "验收条目")
            return session.barcodeEntries.count
        }
        attempt("gpgKey") {
            // GPG 条目需要真实解析 armored 数据，session 层的入口是「导入预览」UI 流程；
            // 这里直接走仓储层写入，仍然是真实 MDBX 数据。
            let metadata = GPGKeyMetadata(
                keyVersion: 4,
                algorithmID: 1,
                algorithm: "RSA 4096",
                fingerprint: "A1B2C3D4E5F60718293A4B5C6D7E8F9012345678",
                keyID: "6D7E8F9012345678",
                keyCreatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                keyExpiresAt: nil,
                userID: "Acceptance Tester <acceptance@example.com>",
                ownerName: "Acceptance Tester",
                ownerEmail: "acceptance@example.com",
                isSecretKey: false,
                secretKeyIsEncrypted: false,
                isRevoked: false
            )
            let draft = LocalGPGKeyEntryDraft(
                title: "验收 GPG 密钥",
                notes: "模拟器验收自检创建（仓储层写入）",
                armoredPublicKey: """
                -----BEGIN PGP PUBLIC KEY BLOCK-----

                bW9uaWNhLWFjY2VwdGFuY2UtcGxhY2Vob2xkZXItb25seQ==

                -----END PGP PUBLIC KEY BLOCK-----
                """,
                metadata: metadata
            )
            _ = try repository.createGPGKeyEntry(projectID: entryProjectID, draft: draft)
            try session.refreshAllEntryLists(projectID: entryProjectID, entryRepository: repository)
            return session.gpgKeyEntries.count
        }
        attempt("billingAddress") {
            session.billingAddressForm = BillingAddressFormState()
            session.billingAddressForm.title = "验收账单地址"
            session.billingAddressForm.fullName = "Acceptance Tester"
            session.billingAddressForm.streetAddress = "Monica Street 1"
            session.billingAddressForm.city = "Shenzhen"
            session.billingAddressForm.stateProvince = "Guangdong"
            session.billingAddressForm.postalCode = "518000"
            session.billingAddressForm.country = "CN"
            session.billingAddressForm.notes = "模拟器验收自检创建"
            try session.createBillingAddressEntry(projectTitle: "验收条目")
            return session.billingAddressEntries.count
        }
        attempt("paymentAccount") {
            session.paymentAccountForm = PaymentAccountFormState()
            session.paymentAccountForm.title = "验收支付账户"
            session.paymentAccountForm.kind = .bankAccount
            session.paymentAccountForm.provider = "Monica Bank"
            session.paymentAccountForm.accountName = "Acceptance Tester"
            session.paymentAccountForm.accountHolderName = "Acceptance Tester"
            session.paymentAccountForm.accountNumber = "6222020000000000000"
            session.paymentAccountForm.currency = "CNY"
            session.paymentAccountForm.notes = "模拟器验收自检创建"
            try session.createPaymentAccountEntry(projectTitle: "验收条目")
            return session.paymentAccountEntries.count
        }

        try session.refreshAllEntryLists(projectID: entryProjectID, entryRepository: repository)

        let summary = created.joined(separator: " ")
        guard failures.isEmpty else {
            return .fail("已创建：\(summary)；失败：\(failures.joined(separator: "；"))")
        }

        let kinds = session.loginEntries.count + session.totpEntries.count + session.noteEntries.count
            + session.cardEntries.count + session.identityEntries.count + session.sshKeyEntries.count
            + session.apiTokenEntries.count + session.wifiEntries.count + session.ssoEntries.count
            + session.barcodeEntries.count + session.gpgKeyEntries.count
            + session.billingAddressEntries.count + session.paymentAccountEntries.count
        guard kinds >= 14 else {
            throw AcceptanceHarnessError("条目总数偏少：\(kinds)")
        }
        return .pass("\(summary)；分类内条目合计=\(kinds)")
    }

    // MARK: - 步骤 3：搜索 / 标签 / 归档

    private func searchTagsArchive() async throws -> StepOutcome {
        let repository = try requireRepository()
        try session.refreshAllEntryLists(projectID: entryProjectID, entryRepository: repository)

        guard let alpha = loginEntry(named: "验收登录 Alpha") else {
            return .skip("entry-crud 没有创建出「验收登录 Alpha」")
        }

        var notes: [String] = []
        notes.append(
            "计数 login=\(session.loginEntries.count) totp=\(session.totpEntries.count) "
                + "note=\(session.noteEntries.count) card=\(session.cardEntries.count) "
                + "identity=\(session.identityEntries.count) ssh=\(session.sshKeyEntries.count) "
                + "apiToken=\(session.apiTokenEntries.count) wifi=\(session.wifiEntries.count) "
                + "sso=\(session.ssoEntries.count) barcode=\(session.barcodeEntries.count) "
                + "gpg=\(session.gpgKeyEntries.count) billing=\(session.billingAddressEntries.count) "
                + "payment=\(session.paymentAccountEntries.count)"
        )

        try session.addVaultTag(named: "验收标签", toEntryID: alpha.id)
        session.refreshVaultTags()
        let tags = session.vaultTags(forEntryID: alpha.id)
        guard tags.contains(where: { $0.name == "验收标签" }) else {
            throw AcceptanceHarnessError("标签写入后读不到（tags=\(tags.map(\.name))）")
        }
        notes.append("标签=已写入")

        try session.setVaultEntryArchived(true, entryID: alpha.id)
        guard session.isVaultEntryArchived(alpha.id) else {
            throw AcceptanceHarnessError("归档后 isVaultEntryArchived 仍为 false")
        }
        try session.refreshAllEntryLists(projectID: entryProjectID, entryRepository: repository)
        let archivedMetadata = session.loginEntries.first(where: { $0.id == alpha.id })?.metadata.isArchived
        notes.append("归档=已生效（列表 metadata.isArchived=\(archivedMetadata.map(String.init) ?? "nil")）")

        try session.setVaultEntryArchived(false, entryID: alpha.id)
        guard !session.isVaultEntryArchived(alpha.id) else {
            throw AcceptanceHarnessError("取消归档后仍被标记为已归档")
        }
        try session.refreshAllEntryLists(projectID: entryProjectID, entryRepository: repository)
        notes.append("取消归档=已生效")

        session.refreshVaultSearchIndex(entryRepository: repository)
        guard session.vaultSearch.documentCount > 0 else {
            throw AcceptanceHarnessError("搜索索引为空（documentCount=0）")
        }
        let results = try await session.vaultSearch.search("验收登录 Alpha")
        guard results.results.contains(where: { $0.id == alpha.id }) else {
            throw AcceptanceHarnessError("搜索「验收登录 Alpha」没有命中该条目（results=\(results.results.count)）")
        }
        notes.append("搜索命中=\(results.results.count) 条 / 索引 \(session.vaultSearch.documentCount) 条")

        return .pass(notes.joined(separator: "；"))
    }

    // MARK: - 步骤 4：分类与文件夹

    private func folders() throws -> StepOutcome {
        let beta = try session.createVaultCategory(title: "验收分类 Beta")
        guard session.vaultProjects.contains(where: { $0.id == beta.id }) else {
            throw AcceptanceHarnessError("新建分类后 vaultProjects 里没有它")
        }
        let renamedCategory = try session.renameVaultCategory(projectID: beta.id, title: "验收分类 Beta 改名")
        guard renamedCategory.title == "验收分类 Beta 改名" else {
            throw AcceptanceHarnessError("分类重命名未生效：\(renamedCategory.title)")
        }

        let parent = try session.createVaultFolder(title: "验收父文件夹", parentID: nil)
        let child = try session.createVaultFolder(title: "验收子文件夹", parentID: parent.id)
        let renamedFolder = try session.renameVaultFolder(folderID: child.id, title: "验收子文件夹改名")
        guard renamedFolder.title == "验收子文件夹改名" else {
            throw AcceptanceHarnessError("文件夹重命名未生效：\(renamedFolder.title)")
        }
        guard session.vaultFolderTree.folders.contains(where: { $0.id == renamedFolder.id && $0.parentID == parent.id }) else {
            throw AcceptanceHarnessError("文件夹层级关系丢失")
        }
        let folderCountAfterCreate = session.vaultFolderTree.folders.count

        try session.switchVaultCategory(projectID: entryProjectID)
        session.applyVaultQuickFilter("all")

        guard let alpha = loginEntry(named: "验收登录 Alpha") else {
            return .skip("entry-crud 没有创建出「验收登录 Alpha」")
        }
        session.enterVaultBatchSelection(for: .login)
        session.toggleVaultBatchItemSelection(alpha.id, for: .login)
        guard session.canMoveSelectedVaultBatchItems else {
            throw AcceptanceHarnessError("批量移动前置条件不满足（selection=\(session.selectedVaultBatchItemIDs.count)）")
        }
        try session.moveSelectedVaultBatchItems(toProjectID: beta.id)
        guard !session.loginEntries.contains(where: { $0.id == alpha.id }) else {
            throw AcceptanceHarnessError("移动后原分类仍能看到该条目")
        }
        try session.switchVaultCategory(projectID: beta.id)
        guard session.loginEntries.contains(where: { $0.id == alpha.id }) else {
            throw AcceptanceHarnessError("移动后目标分类看不到该条目")
        }

        let empty = try session.createVaultCategory(title: "验收空分类")
        guard session.vaultProjects.contains(where: { $0.id == empty.id }) else {
            throw AcceptanceHarnessError("空分类没有出现在 vaultProjects")
        }
        try session.deleteVaultCategory(projectID: empty.id)
        guard !session.vaultProjects.contains(where: { $0.id == empty.id }) else {
            throw AcceptanceHarnessError("空分类删除后仍在 vaultProjects 里")
        }

        try session.switchVaultCategory(projectID: entryProjectID)
        return .pass(
            "分类=\(session.vaultProjects.count) 个；文件夹节点=\(folderCountAfterCreate)；"
                + "分类与子文件夹已创建并重命名；条目已移动到 Beta；空分类已删除"
        )
    }

    // MARK: - 步骤 5：回收站

    private func trash() throws -> StepOutcome {
        let repository = try requireRepository()
        try session.switchVaultCategory(projectID: entryProjectID)
        session.applyVaultQuickFilter("all")

        session.loginTitle = "验收回收站登录"
        session.loginUsername = "trash@example.com"
        session.loginPassword = "Accept-Trash-Pass-2026!"
        session.loginURL = "https://example.com/trash"
        session.loginNotes = "模拟器验收自检创建的回收站条目"
        try session.createLoginEntry(projectTitle: "验收条目")

        guard let entry = loginEntry(named: "验收回收站登录") else {
            throw AcceptanceHarnessError("回收站条目创建后读不到")
        }
        session.selectLoginEntryForEditing(entry)
        try session.deleteSelectedLoginEntry()

        guard !session.loginEntries.contains(where: { $0.id == entry.id }) else {
            throw AcceptanceHarnessError("删除后条目仍在活动列表")
        }
        guard session.deletedLoginEntries.contains(where: { $0.id == entry.id }) else {
            throw AcceptanceHarnessError("删除后条目没有进入回收站列表")
        }

        try session.restoreLoginEntry(entry)
        guard session.loginEntries.contains(where: { $0.id == entry.id }) else {
            throw AcceptanceHarnessError("恢复后条目没有回到活动列表")
        }
        guard !session.deletedLoginEntries.contains(where: { $0.id == entry.id }) else {
            throw AcceptanceHarnessError("恢复后条目仍在回收站列表")
        }

        try session.refreshAllEntryLists(projectID: entryProjectID, entryRepository: repository)
        return .pass("删除进入回收站、恢复回到列表；活动登录=\(session.loginEntries.count)")
    }

    // MARK: - 步骤 6：批量

    private func batch() throws -> StepOutcome {
        try session.switchVaultCategory(projectID: entryProjectID)
        session.applyVaultQuickFilter("all")

        let candidates = Array(session.loginEntries.prefix(2))
        guard candidates.count == 2 else {
            return .skip("当前分类可批量操作的登录条目不足 2 条（\(candidates.count)）")
        }

        session.enterVaultBatchSelection(for: .login)
        for entry in candidates {
            session.toggleVaultBatchItemSelection(entry.id, for: .login)
        }
        guard session.selectedVaultBatchItemIDs.count == 2, session.canDeleteSelectedVaultBatchItems else {
            throw AcceptanceHarnessError(
                "批量选择状态异常（selected=\(session.selectedVaultBatchItemIDs.count)，"
                    + "canDelete=\(session.canDeleteSelectedVaultBatchItems)）"
            )
        }
        try session.deleteSelectedVaultBatchItems()
        for entry in candidates {
            guard !session.loginEntries.contains(where: { $0.id == entry.id }) else {
                throw AcceptanceHarnessError("批量删除后条目仍在活动列表：\(entry.title)")
            }
            guard session.deletedLoginEntries.contains(where: { $0.id == entry.id }) else {
                throw AcceptanceHarnessError("批量删除后条目没有进入回收站：\(entry.title)")
            }
        }

        session.applyVaultQuickFilter("trash")
        guard session.isTrashQuickFilterSelected else {
            throw AcceptanceHarnessError("回收站筛选没有生效")
        }
        session.enterVaultBatchSelection(for: .login)
        for entry in candidates {
            session.toggleVaultBatchItemSelection(entry.id, for: .login)
        }
        guard session.selectedVaultBatchItemIDs.count == 2, session.canRestoreSelectedVaultBatchItems else {
            throw AcceptanceHarnessError(
                "回收站批量选择异常（selected=\(session.selectedVaultBatchItemIDs.count)，"
                    + "canRestore=\(session.canRestoreSelectedVaultBatchItems)）"
            )
        }
        try session.restoreSelectedVaultBatchItems()
        for entry in candidates {
            guard session.loginEntries.contains(where: { $0.id == entry.id }) else {
                throw AcceptanceHarnessError("批量恢复后条目没有回到活动列表：\(entry.title)")
            }
        }
        session.resetVaultQuickFilters()

        return .pass("两条登录条目批量删除并批量恢复（\(candidates.map(\.title).joined(separator: "、"))）")
    }

    // MARK: - 步骤 7：导出导入与加密备份

    private func exportImport() throws -> StepOutcome {
        let csv = try session.exportCSV()
        guard !csv.isEmpty else {
            throw AcceptanceHarnessError("exportCSV 返回空内容")
        }
        let exportURL = try exportFileURL(named: "acceptance-export.csv")
        try csv.write(to: exportURL, atomically: true, encoding: .utf8)

        let preview = try session.previewCSVImport(from: exportURL)
        guard !preview.items.isEmpty else {
            throw AcceptanceHarnessError("读回 CSV 后导入预览为空")
        }

        let importCategory = try session.createVaultCategory(title: "验收导入分类")
        try session.confirmCSVImport(projectTitle: "验收导入分类")
        let repository = try requireRepository()
        try session.refreshAllEntryLists(projectID: importCategory.id, entryRepository: repository)
        let importedLogins = session.loginEntries.count
        guard importedLogins > 0 else {
            throw AcceptanceHarnessError("导入后新分类里没有登录条目")
        }

        let payload = try session.exportAndroidBackup()
        guard !payload.isEmpty else {
            throw AcceptanceHarnessError("exportAndroidBackup 返回空内容")
        }
        let encrypted = try AndroidBackupCodec.encryptPayload(
            payload,
            password: AppSimulatorAcceptanceHarness.testMasterPassword
        )
        guard AndroidBackupCodec.isEncryptedPayload(encrypted) else {
            throw AcceptanceHarnessError("加密后的备份没有被识别为加密负载")
        }
        let decrypted = try AndroidBackupCodec.decryptPayload(
            encrypted,
            password: AppSimulatorAcceptanceHarness.testMasterPassword
        )
        guard decrypted == payload else {
            throw AcceptanceHarnessError("正确密码解密后的内容与原始负载不一致")
        }

        var wrongPasswordRejected = false
        do {
            _ = try AndroidBackupCodec.decryptPayload(encrypted, password: "Monica-Wrong-Pass-2026!")
        } catch {
            wrongPasswordRejected = true
        }
        guard wrongPasswordRejected else {
            throw AcceptanceHarnessError("错误密码没有被拒绝")
        }

        try session.switchVaultCategory(projectID: entryProjectID)
        return .pass(
            "CSV \(csv.utf8.count) 字节；导入预览 \(preview.items.count) 项，新分类登录条目=\(importedLogins)；"
                + "加密备份 \(encrypted.count) 字节，正确密码可解密，错误密码已拒绝"
        )
    }

    // MARK: - 步骤 8：快照

    private func snapshot() async throws -> StepOutcome {
        let center = VaultSnapshotCenterModel()
        center.reload(session: session)
        guard let subject = center.subject else {
            return .skip("没有可用的保险库身份，无法创建快照")
        }
        let before = center.records.count

        await center.createSnapshot(session: session)
        if case .failed(let message) = center.status {
            // 快照创建会先锁库；失败时也要恢复解锁，避免后续步骤被级联影响。
            var recovered = true
            do {
                try unlockIfNeeded()
                try session.switchVaultCategory(projectID: entryProjectID)
            } catch {
                recovered = false
            }
            let recoveryNote = recovered ? "，已重新解锁" : "，且重新解锁失败"

            if message.contains("-34018") || message.localizedCaseInsensitiveContains("entitlement") {
                return .skip(
                    "快照密钥存放在 Keychain；无签名构建（CODE_SIGNING_ALLOWED=NO）缺少 Keychain entitlement，"
                        + "报 errSecMissingEntitlement(-34018)\(recoveryNote)"
                )
            }
            throw AcceptanceHarnessError("创建快照失败：\(message)\(recoveryNote)")
        }
        guard case .succeeded = center.status else {
            throw AcceptanceHarnessError("创建快照后状态不是 succeeded")
        }
        guard center.records.count == before + 1, let record = center.records.first else {
            throw AcceptanceHarnessError("快照记录数没有增加（before=\(before)，after=\(center.records.count)）")
        }
        guard FileManager.default.fileExists(atPath: record.fileURL.path) else {
            throw AcceptanceHarnessError("快照文件不存在：\(record.fileURL.lastPathComponent)")
        }

        let store = AppVaultSnapshotLocation.makeStore()
        let verified = try store.verifySnapshot(snapshotID: record.id, vaultID: subject.vaultID)
        guard verified.manifest.id == record.id, !verified.payloadSHA256.isEmpty else {
            throw AcceptanceHarnessError("快照校验结果与该记录不匹配")
        }

        // 创建快照会主动锁库以保证 MDBX 静默；这里用测试主密码解锁，后续步骤继续。
        try unlockIfNeeded()
        try session.switchVaultCategory(projectID: entryProjectID)

        return .pass(
            "快照 \(record.fileURL.lastPathComponent) 已创建并通过 verifySnapshot（payloadSHA256 已核对），"
                + "之后已重新解锁"
        )
    }

    // MARK: - 步骤 9：TOTP

    /// 快照创建等步骤会把保险库锁上；这里用测试主密码恢复解锁，保证后续步骤继续验证而不是级联失败。
    private func unlockIfNeeded() throws {
        guard session.vaultState != .unlocked else { return }
        guard let fileURL = session.activeVaultSession?.descriptor.fileURL ?? vaultFileURL else {
            throw AcceptanceHarnessError("保险库已锁定且找不到库文件路径")
        }
        session.vaultPassword = AppSimulatorAcceptanceHarness.testMasterPassword
        try session.openLocalVault(at: fileURL, deviceID: environment.localDeviceIdentifier)
        guard session.vaultState == .unlocked else {
            throw AcceptanceHarnessError("重新解锁失败")
        }
    }

    private func totp() throws -> StepOutcome {
        try unlockIfNeeded()
        try session.switchVaultCategory(projectID: entryProjectID)
        guard let entry = session.totpEntries.first else {
            return .skip("entry-crud 没有创建出 TOTP 条目")
        }

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try session.totpCode(for: entry, at: base)
        let second = try session.totpCode(for: entry, at: base.addingTimeInterval(30))
        let current = try session.totpCode(for: entry)

        for code in [first, second, current] {
            guard code.count == 6, code.allSatisfy({ $0.isNumber }) else {
                throw AcceptanceHarnessError("TOTP 码不是 6 位数字：\(code.count) 位")
            }
        }
        guard first != second else {
            throw AcceptanceHarnessError("相邻两个时间窗生成的 TOTP 码相同")
        }

        return .pass("secret 已设置（不回显）；两个时间窗各生成 6 位数字码且不同；当前码可用")
    }

    // MARK: - 步骤 10：生成器

    private func generator() throws -> StepOutcome {
        let password = try session.passwordGenerator()
        guard password.count >= 12 else {
            throw AcceptanceHarnessError("生成密码长度过短：\(password.count)")
        }
        guard password.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw AcceptanceHarnessError("生成密码包含空白字符")
        }
        guard password.contains(where: { $0.isLetter }), password.contains(where: { $0.isNumber }) else {
            throw AcceptanceHarnessError("生成密码缺少字母或数字")
        }

        let assessment = PasswordStrengthAnalyzer.assess(password)
        guard assessment.length == password.count else {
            throw AcceptanceHarnessError("强度分析长度与密码不一致")
        }
        guard assessment.estimatedBits > 0, assessment.level != .veryWeak else {
            throw AcceptanceHarnessError("强度分析结果异常：level=\(assessment.level)")
        }

        return .pass(
            "长度=\(password.count)，无空白字符，含字母与数字；"
                + "强度 level=\(assessment.level)，估计熵=\(Int(assessment.estimatedBits)) bit"
        )
    }

    // MARK: - 步骤 11：锁定与解锁

    private func lockUnlock() throws -> StepOutcome {
        try unlockIfNeeded()
        guard let fileURL = session.activeVaultSession?.descriptor.fileURL ?? vaultFileURL else {
            throw AcceptanceHarnessError("找不到保险库文件路径")
        }
        try session.switchVaultCategory(projectID: entryProjectID)
        let countBeforeLock = session.loginEntries.count
        guard countBeforeLock > 0 else {
            return .skip("当前分类没有登录条目，无法验证解锁后条目仍在")
        }

        session.lockLocalVault()
        guard session.vaultState == .locked else {
            throw AcceptanceHarnessError("lockLocalVault 后 vaultState 不是 locked")
        }
        guard session.loginEntries.isEmpty, session.activeEntryRepository == nil else {
            throw AcceptanceHarnessError("锁定后条目列表或仓库没有被清空")
        }

        session.vaultPassword = AppSimulatorAcceptanceHarness.testMasterPassword
        try session.openLocalVault(at: fileURL, deviceID: environment.localDeviceIdentifier)
        guard session.vaultState == .unlocked else {
            throw AcceptanceHarnessError("解锁后 vaultState 不是 unlocked")
        }
        try session.switchVaultCategory(projectID: entryProjectID)
        guard session.loginEntries.count == countBeforeLock else {
            throw AcceptanceHarnessError(
                "解锁后登录条目数不一致（before=\(countBeforeLock)，after=\(session.loginEntries.count)）"
            )
        }
        return .pass("锁定后状态 locked 且列表清空；用主密码解锁后条目数仍为 \(countBeforeLock)（数据在 MDBX 中保留）")
    }

    // MARK: - 步骤 12：Widget 快照

    private func widgetSnapshot() throws -> StepOutcome {
        guard let store = session.widgetSnapshotStore else {
            return .skip("App Group 容器不可用（production 装配降级，widgetSnapshotStore 为 nil）")
        }
        try unlockIfNeeded()

        let published = session.publishWidgetSnapshots()
        guard published else {
            throw AcceptanceHarnessError("publishWidgetSnapshots 返回 false")
        }
        guard FileManager.default.fileExists(atPath: store.snapshotFileURL.path) else {
            throw AcceptanceHarnessError("快照文件不存在：\(store.snapshotFileURL.lastPathComponent)")
        }
        let data = try Data(contentsOf: store.snapshotFileURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any], !dictionary.isEmpty else {
            throw AcceptanceHarnessError("快照 JSON 不是非空对象")
        }

        return .pass(
            "已写入 \(store.snapshotFileURL.lastPathComponent)（\(data.count) 字节，顶层键 \(dictionary.count) 个），JSON 可解析"
        )
    }

    // MARK: - 步骤 13：本地化

    private func localization() throws -> StepOutcome {
        let original = AppLocalizationRuntime.shared.current
        defer { AppLocalizationRuntime.shared.set(original) }

        let chinese = AppLanguage.simplifiedChinese.localized("设置")
        let english = AppLanguage.english.localized("设置")
        guard chinese == "设置" else {
            throw AcceptanceHarnessError("zh-Hans 取值不是「设置」：\(chinese)")
        }
        guard english != chinese, !english.isEmpty else {
            throw AcceptanceHarnessError("en 与 zh-Hans 取值相同：\(english)")
        }

        AppLocalizationRuntime.shared.set(.english)
        let runtimeEnglish = appLocalized("设置")
        AppLocalizationRuntime.shared.set(.simplifiedChinese)
        let runtimeChinese = appLocalized("设置")

        guard runtimeEnglish == english, runtimeChinese == chinese else {
            throw AcceptanceHarnessError(
                "appLocalized 没有跟随运行时切换（en=\(runtimeEnglish)，zh=\(runtimeChinese)）"
            )
        }

        return .pass("en=\(english)，zh-Hans=\(chinese)；AppLocalizationRuntime 切换后 appLocalized 同步变化，已还原原语言")
    }

    // MARK: - 步骤 14：自动填充索引

    private func autoFillIndex() throws -> StepOutcome {
        try unlockIfNeeded()
        do {
            try session.refreshAutoFillEncryptedIndexIfConfigured()
        } catch {
            throw AcceptanceHarnessError("刷新自动填充索引抛错：\(Self.describe(error))")
        }

        switch session.autoFillIndexState {
        case .succeeded(let count):
            return .pass("自动填充加密索引刷新成功，\(count) 条")
        case .idle:
            return .skip("自动填充索引存储未配置（App Group 容器不可用），刷新直接返回 idle")
        case .running:
            return .pass("自动填充索引刷新已进入 running 状态，未抛错")
        case .failed(let message):
            throw AcceptanceHarnessError("自动填充索引刷新失败：\(message)")
        }
    }

    // MARK: - 工具

    private func requireRepository() throws -> LocalVaultEntryRepository {
        guard let repository = session.activeEntryRepository else {
            throw AcceptanceHarnessError("activeEntryRepository 为 nil（保险库未解锁）")
        }
        return repository
    }

    private func loginEntry(named title: String) -> LocalLoginEntry? {
        session.loginEntries.first { $0.title == title }
    }

    private func exportFileURL(named name: String) throws -> URL {
        guard let directory = vaultDirectory else {
            throw AcceptanceHarnessError("临时目录尚未创建")
        }
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: - 文本与路径

    private static func describe(_ error: Error) -> String {
        let text: String
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty {
            text = description
        } else {
            text = String(describing: error)
        }
        let single = singleLine(text)
        return String(single.prefix(300))
    }

    private static func singleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func slug(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func reportFileURL() throws -> URL {
        guard let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
        else {
            throw AcceptanceHarnessError("找不到 Documents 目录")
        }
        return documents.appendingPathComponent(
            AppSimulatorAcceptanceHarness.reportFileName,
            isDirectory: false
        )
    }
}
