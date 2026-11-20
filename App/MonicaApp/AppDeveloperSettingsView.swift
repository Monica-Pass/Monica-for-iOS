import MonicaCore
import SwiftUI
import UniformTypeIdentifiers

/// Plain-text document used by the developer diagnostics export (issue #65).
struct TextExportDocument: FileDocument, Sendable {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else {
            self.text = ""
            return
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Developer diagnostics screen (issue #65).
///
/// Only reachable after the version row is tapped seven times, and every read
/// and export path goes through `DiagnosticLog`, which refuses to hand back the
/// buffer while the vault is locked. The export confirmation names exactly what
/// the file can contain, and nothing here uploads anything anywhere.
struct AppDeveloperSettingsView: View {
    let session: AppSessionModel
    let center: AppDiagnosticsCenter
    let appGroupIdentifier: String

    @State private var showClearConfirmation = false
    @State private var showExportConfirmation = false
    @State private var isExporterPresented = false
    @State private var isImporterRefreshRunning = false
    @State private var exportDocument = TextExportDocument()
    @State private var exportFileName = AppDiagnosticsCenter.exportBaseFileName
    @State private var exportErrorText: String?
    @State private var lastImportedCount: Int?

    private var vaultIsUnlocked: Bool {
        session.vaultState == .unlocked
    }

    private var displayLevelBinding: Binding<DiagnosticLevel> {
        Binding {
            center.displayLevel
        } set: { level in
            center.displayLevel = level
            center.reloadEvents(vaultIsUnlocked: vaultIsUnlocked)
        }
    }

    private var recordingLevelBinding: Binding<DiagnosticLevel> {
        Binding {
            center.recordingLevel
        } set: { level in
            center.recordingLevel = level
            center.reloadEvents(vaultIsUnlocked: vaultIsUnlocked)
        }
    }

    private var includesHostNamesBinding: Binding<Bool> {
        Binding {
            center.includesHostNames
        } set: { enabled in
            center.includesHostNames = enabled
            center.reloadEvents(vaultIsUnlocked: vaultIsUnlocked)
        }
    }

    var body: some View {
        AndroidParityScreen {
            AndroidParitySection(title: "诊断日志") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                    AndroidParityInfoRow(
                        title: "保险库状态",
                        value: vaultIsUnlocked ? String(localized: "已解锁") : String(localized: "已锁定")
                    )
                    AndroidParityDivider()
                    AndroidParityInfoRow(
                        title: "缓冲条目",
                        value: "\(center.events.count) / \(center.log.capacity)"
                    )
                    AndroidParityInfoRow(
                        title: "保留窗口",
                        value: String(localized: "\(Int(center.log.retention / 86_400)) 天")
                    )
                    Picker("显示级别", selection: displayLevelBinding) {
                        ForEach(DiagnosticLevel.developerCases, id: \.self) { level in
                            Text(level.developerLabel).tag(level)
                        }
                    }
                }
            }

            AndroidParitySection(title: "预览功能 · 实验性") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                    Toggle(isOn: recordingLevelBinding.recordingDebugEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("记录详细事件")
                                .foregroundStyle(AndroidParityPalette.textPrimary)
                            Text("Release 默认只记录信息级及以上；开启后记录调试级事件。")
                                .font(.footnote)
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                        }
                    }
                    AndroidParityDivider()
                    Toggle(isOn: includesHostNamesBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("记录域名")
                                .foregroundStyle(AndroidParityPalette.textPrimary)
                            Text("仅记录主机名，不记录路径、查询参数或账号信息。")
                                .font(.footnote)
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                        }
                    }
                }
            }

            AndroidParitySection(title: "操作") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                    Button {
                        Task { await refreshFromExtension() }
                    } label: {
                        Label("导入自动填充扩展日志", systemImage: "arrow.down.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(isImporterRefreshRunning)

                    if let lastImportedCount {
                        Text("已导入 \(lastImportedCount) 条扩展事件")
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }

                    Button {
                        center.reloadEvents(vaultIsUnlocked: vaultIsUnlocked)
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))

                    AndroidParityDivider()

                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("清理本机诊断日志", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))

                    Button {
                        showExportConfirmation = true
                    } label: {
                        Label("导出诊断日志", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    .disabled(!vaultIsUnlocked)
                    .opacity(vaultIsUnlocked ? 1 : 0.5)

                    if !vaultIsUnlocked {
                        Text("保险库锁定期间无法浏览或导出诊断日志。")
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                    if let exportErrorText {
                        Text(exportErrorText)
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }

                    AndroidParityDivider()

                    Button(role: .destructive) {
                        center.hideDeveloperMode()
                    } label: {
                        Label("关闭开发者模式", systemImage: "lock")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
                }
            }

            AndroidParitySection(title: "事件") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                    if !vaultIsUnlocked {
                        Text("保险库已锁定，无法查看受保护诊断。")
                            .font(.subheadline)
                            .foregroundStyle(AndroidParityPalette.textPrimary)
                    } else if center.events.isEmpty {
                        Text("暂无事件。")
                            .font(.subheadline)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    } else {
                        Text(verbatim: Self.renderLines(center.events))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("开发者")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            center.reloadEvents(vaultIsUnlocked: vaultIsUnlocked)
        }
        .onChange(of: session.vaultState) { _, _ in
            center.reloadEvents(vaultIsUnlocked: vaultIsUnlocked)
        }
        .confirmationDialog(
            "清理本机诊断日志？",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清理诊断日志", role: .destructive) {
                center.clear()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清除本机环形缓冲中的诊断事件，不会删除保险库内容或云端备份。")
        }
        .confirmationDialog(
            "导出诊断日志？",
            isPresented: $showExportConfirmation,
            titleVisibility: .visible
        ) {
            Button("继续导出") {
                prepareExport()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("导出文件仅保存在你选择的位置，可能包含时间戳、日志级别、模块名称、事件码与域名（不含路径或查询参数）。不会包含密码、验证码、令牌、密钥或完整 URL，也不会自动上传到任何服务器。")
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: exportFileName
        ) { result in
            if case .failure(let error) = result {
                exportErrorText = String(localized: "导出失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Actions

    private func prepareExport() {
        guard vaultIsUnlocked else {
            exportErrorText = String(localized: "保险库锁定期间无法导出诊断日志。")
            return
        }
        do {
            exportDocument = TextExportDocument(
                text: try center.exportReport(vaultIsUnlocked: vaultIsUnlocked)
            )
            exportFileName = center.exportFileName()
            exportErrorText = nil
            isExporterPresented = true
        } catch {
            exportErrorText = String(localized: "导出失败：\(error.localizedDescription)")
        }
    }

    private func refreshFromExtension() async {
        isImporterRefreshRunning = true
        defer { isImporterRefreshRunning = false }
        lastImportedCount = center.importExtensionEvents(appGroupIdentifier: appGroupIdentifier)
        center.reloadEvents(vaultIsUnlocked: vaultIsUnlocked)
    }

    private static func renderLines(_ events: [DiagnosticEvent]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return events
            .reversed()
            .map { $0.renderLine(using: formatter) }
            .joined(separator: "\n")
    }
}

extension DiagnosticLevel {
    static var developerCases: [DiagnosticLevel] {
        [.debug, .info, .warning, .error]
    }

    var developerLabel: String {
        switch self {
        case .debug: return String(localized: "详细")
        case .info: return String(localized: "信息")
        case .warning: return String(localized: "警告")
        case .error: return String(localized: "错误")
        }
    }
}

private extension Binding where Value == DiagnosticLevel {
    /// Reinterprets a level binding as "detailed logging on/off" for the toggle.
    var recordingDebugEnabled: Binding<Bool> {
        Binding<Bool> {
            wrappedValue == .debug
        } set: { enabled in
            wrappedValue = enabled ? .debug : .info
        }
    }
}
