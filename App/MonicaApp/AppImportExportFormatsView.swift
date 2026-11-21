//
//  AppImportExportFormatsView.swift
//  Monica
//
//  issue #37：CSV / JSON / Bitwarden / Aegis / Stratum 的格式导入与导出入口。
//

import MonicaStorage
import SwiftUI
import UniformTypeIdentifiers

/// 迁移页的「格式导入导出」卡片：导入只做预览，确认后才写库；导出默认建议加密。
struct VaultFormatImportExportCard: View {
    @Bindable var session: AppSessionModel

    @State private var isImporterPresented = false
    @State private var isExporterPresented = false
    @State private var exportDocument = VaultExportDocument()
    @State private var exportContentType: UTType = .json
    @State private var exportFileName = "Monica-Vault"
    @State private var isPlaintextConfirmationPresented = false
    @State private var isShowingAllIssues = false

    @State private var exportFormat: VaultExportFormat = .json
    @State private var includeCustomFields = true
    @State private var encryptionPassword = ""

    private var preview: FormatImportPreview? {
        session.formatImportPreview
    }

    private var visibleIssues: [VaultImportIssue] {
        guard let preview else {
            return []
        }
        return isShowingAllIssues ? preview.issues : Array(preview.issues.prefix(5))
    }

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            importContent
            AndroidParityDivider()
            exportContent
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.commaSeparatedText, .json, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let fileURL = urls.first else {
                    return
                }
                do {
                    _ = try session.beginFormatImport(from: fileURL)
                } catch {
                    session.entryOperationState = .failed(error.localizedDescription)
                }
            case .failure(let error):
                session.entryOperationState = .failed(error.localizedDescription)
            }
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFileName
        ) { result in
            switch result {
            case .success:
                session.entryOperationState = .succeeded(String(localized: "导出文件已保存"))
            case .failure(let error):
                session.entryOperationState = .failed(error.localizedDescription)
            }
        }
        .confirmationDialog(
            Text("导出明文文件？"),
            isPresented: $isPlaintextConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("导出明文", role: .destructive) {
                performExport()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("明文文件里的密码、TOTP 密钥和备注不会被加密，任何能读取该文件的人都能看到。建议设置导出密码，或导出后立即妥善保管。")
        }
    }

    @ViewBuilder
    private var importContent: some View {
        AndroidParityInfoRow(title: String(localized: "格式导入"), value: String(localized: "自动识别"))
        Text("支持 Monica CSV/JSON、Bitwarden（未加密 JSON）、Aegis、Stratum、1Password CSV 与通用 CSV。加密文件需要输入导出密码；识别不确定时会给出提示。")
            .font(.footnote)
            .foregroundStyle(AndroidParityPalette.textSecondary)

        Button {
            isImporterPresented = true
        } label: {
            Label("选择导入文件", systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AndroidParityButtonStyle(tone: .filled))
        .disabled(session.vaultState != .unlocked)

        if let preview {
            AndroidParityDivider()
            AndroidParityInfoRow(title: String(localized: "识别格式"), value: preview.formatName)
            if let fileName = preview.fileName {
                AndroidParityInfoRow(title: String(localized: "文件"), value: fileName)
            }
            AndroidParityInfoRow(title: String(localized: "可导入条目"), value: "\(preview.itemCount)")
            AndroidParityInfoRow(
                title: String(localized: "跳过条目"),
                value: "\(preview.skippedItemCount) / \(preview.sourceItemCount)"
            )
            if preview.skippedDuplicateCount > 0 {
                AndroidParityInfoRow(title: String(localized: "重复条目"), value: "\(preview.skippedDuplicateCount)")
            }

            ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }

            if preview.needsPassword {
                SecureField("文件密码", text: $session.formatImportPassword)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button {
                    _ = session.previewEncryptedFormatImport()
                } label: {
                    Label("用密码解密预览", systemImage: "lock.open")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                .disabled(session.formatImportPassword.isEmpty)
            }

            if !preview.issues.isEmpty {
                Text("问题摘要")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                ForEach(Array(visibleIssues.enumerated()), id: \.offset) { _, issue in
                    Text(issue.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if preview.issues.count > 5 {
                    Button {
                        isShowingAllIssues.toggle()
                    } label: {
                        if isShowingAllIssues {
                            Text("收起问题")
                        } else {
                            Text("查看全部问题（\(preview.issues.count)）")
                        }
                    }
                    .font(.caption)
                }
            }

            HStack(spacing: 10) {
                Button {
                    do {
                        _ = try session.confirmFormatImport(projectTitle: String(localized: "格式导入"))
                    } catch {
                        // AppSessionModel 已经写入用户可见的失败状态。
                    }
                } label: {
                    Label("确认导入", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                .disabled(!preview.canImport)

                Button {
                    isShowingAllIssues = false
                    session.cancelFormatImport()
                } label: {
                    Label("取消", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }
        }
    }

    @ViewBuilder
    private var exportContent: some View {
        AndroidParityInfoRow(title: String(localized: "格式导出"), value: String(localized: "CSV / JSON"))
        Picker("导出格式", selection: $exportFormat) {
            ForEach(VaultExportFormat.allCases, id: \.self) { format in
                Text(format.displayName).tag(format)
            }
        }
        .pickerStyle(.segmented)

        Toggle("包含自定义字段", isOn: $includeCustomFields)

        SecureField("导出密码（可选）", text: $encryptionPassword)
            .textContentType(.newPassword)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

        Text(
            encryptionPassword.isEmpty
                ? "不设置密码会导出明文文件，导出前会再确认一次。"
                : "使用 MONICA_ENC_V1 加密，导入时需要同一个密码。"
        )
        .font(.caption)
        .foregroundStyle(encryptionPassword.isEmpty ? .orange : AndroidParityPalette.textSecondary)

        Button {
            if encryptionPassword.isEmpty {
                isPlaintextConfirmationPresented = true
            } else {
                performExport()
            }
        } label: {
            Label("导出文件", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AndroidParityButtonStyle(tone: .filled))
        .disabled(session.vaultState != .unlocked)
    }

    private func performExport() {
        do {
            let artifact = try session.exportTransferArtifact(
                format: exportFormat,
                includeCustomFields: includeCustomFields,
                encryptionPassword: encryptionPassword.isEmpty ? nil : encryptionPassword
            )
            exportDocument = VaultExportDocument(data: artifact.data, contentType: exportFormat.contentType)
            exportContentType = exportFormat.contentType
            exportFileName = artifact.fileName
            // 密码只用于这一次导出，生成文件后立刻清掉。
            encryptionPassword = ""
            isExporterPresented = true
        } catch {
            session.entryOperationState = .failed(error.localizedDescription)
        }
    }
}
