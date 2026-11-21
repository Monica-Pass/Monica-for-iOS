import Foundation
import MonicaStorage
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 显示模式

enum AppNoteMarkdownDisplayMode: Hashable {
    case edit
    case preview
}

// MARK: - 笔记编辑器（编辑 / 预览 + 图片）

/// 笔记正文的 Markdown 编辑器：文本编辑、受限预览、加密图片插入与草稿恢复入口。
/// 只支持 Monica 声明的 Markdown 子集，不追求完整 CommonMark；外部图片一律不加载。
struct AppNoteMarkdownComposer: View {
    let session: AppSessionModel
    @Binding var title: String
    @Binding var markdownBody: String
    let noteID: String?

    @State private var displayMode: AppNoteMarkdownDisplayMode = .edit
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isFileImporterPresented = false
    @State private var errorMessage: String?
    @State private var pendingDraft: NoteDraft?
    @State private var didResolveDraft = false

    private var referencedAttachmentIDs: [String] {
        NoteMarkdownAttachmentReference.attachmentIDs(in: markdownBody)
    }

    private var remainingImageSlots: Int {
        max(0, NoteMarkdownImageLimits.maximumImagesPerNote - referencedAttachmentIDs.count)
    }

    private var draftID: String {
        AppNoteDraftPolicy.draftID(noteID: noteID)
    }

    private var autosaveToken: String {
        "\(title)\u{1}\(markdownBody)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pendingDraft, !didResolveDraft {
                draftBanner(pendingDraft)
            }
            Picker("显示模式", selection: $displayMode) {
                Text("编辑").tag(AppNoteMarkdownDisplayMode.edit)
                Text("预览").tag(AppNoteMarkdownDisplayMode.preview)
            }
            .pickerStyle(.segmented)

            switch displayMode {
            case .edit:
                editorCard
            case .preview:
                previewCard
            }

            imageToolbar
            if !referencedAttachmentIDs.isEmpty {
                attachmentStrip
            }
            Text("支持常用 Markdown 子集：标题、列表、引用、代码、强调与链接；不支持完整 CommonMark。外部图片不会自动加载。")
                .font(.caption2)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { loadPendingDraftIfNeeded() }
        .task(id: autosaveToken) {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else {
                return
            }
            _ = session.autosaveNoteDraftIfNeeded()
        }
        .alert(
            "无法插入图片",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: 编辑 / 预览

    private var editorCard: some View {
        TextEditor(text: $markdownBody)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 220)
            .padding(12)
            .scrollContentBackground(.hidden)
            .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1) }
            .overlay(alignment: .topLeading) {
                if markdownBody.isEmpty {
                    Text("用 Markdown 写笔记，例如 # 标题、- 列表、> 引用")
                        .font(.callout)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 20)
                        .allowsHitTesting(false)
                }
            }
    }

    private var previewCard: some View {
        AppNoteMarkdownPreview(
            document: NoteMarkdownDocument.parse(markdownBody),
            session: session
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1) }
    }

    // MARK: 图片

    private var imageToolbar: some View {
        HStack(spacing: 10) {
            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: max(1, remainingImageSlots),
                matching: .images
            ) {
                Label("插入图片", systemImage: "photo.badge.plus")
                    .font(.footnote.weight(.semibold))
            }
            .disabled(remainingImageSlots == 0)

            Button {
                isFileImporterPresented = true
            } label: {
                Label("从文件插入", systemImage: "folder.badge.plus")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(remainingImageSlots == 0)

            Spacer(minLength: 8)

            Text("图片 \(referencedAttachmentIDs.count)/\(NoteMarkdownImageLimits.maximumImagesPerNote)")
                .font(.caption)
                .foregroundStyle(remainingImageSlots == 0 ? AndroidParityPalette.primaryDeep : AndroidParityPalette.textSecondary)
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else {
                return
            }
            Task { await importPickedPhotos(items) }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    importImageFile(at: url)
                }
            case .failure:
                errorMessage = String(localized: "无法读取所选文件，请重新选择。")
            }
        }
    }

    private var attachmentStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("正文引用的图片")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(referencedAttachmentIDs, id: \.self) { attachmentID in
                        attachmentMenuItem(attachmentID: attachmentID)
                    }
                }
                .padding(.vertical, 2)
            }
            Text("单张上限 \(NoteMarkdownImageInspector.formattedByteCount(NoteMarkdownImageLimits.maximumBytesPerImage))，单条笔记最多 \(NoteMarkdownImageLimits.maximumImagesPerNote) 张。图片以加密附件存储，预览时才解密。")
                .font(.caption2)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func attachmentMenuItem(attachmentID: String) -> some View {
        let attachment = session.noteImageAttachment(withID: attachmentID)
        return Menu {
            Button("移除引用", role: .destructive) {
                markdownBody = AppNoteDraftPolicy.removingImageReferences(attachmentID: attachmentID, from: markdownBody)
                _ = session.autosaveNoteDraftIfNeeded()
            }
            if let attachment {
                Button("删除附件", role: .destructive) {
                    markdownBody = AppNoteDraftPolicy.removingImageReferences(attachmentID: attachmentID, from: markdownBody)
                    try? session.deleteAttachmentEntry(attachment)
                    AppNoteImageCache.shared.removeImage(for: attachmentID)
                    _ = session.autosaveNoteDraftIfNeeded()
                }
            }
        } label: {
            AppNoteMarkdownThumbnail(
                attachment: attachment,
                attachmentID: attachmentID,
                session: session
            )
        }
    }

    private func importPickedPhotos(_ items: [PhotosPickerItem]) async {
        photoItems = []
        for (offset, item) in items.enumerated() {
            guard referencedAttachmentIDs.count < NoteMarkdownImageLimits.maximumImagesPerNote else {
                errorMessage = NoteMarkdownImageError
                    .imageLimitReached(limit: NoteMarkdownImageLimits.maximumImagesPerNote)
                    .localizedDescription
                return
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw NoteMarkdownImageError.unreadableImage
                }
                try appendImageAttachment(
                    plaintext: data,
                    fileName: "note-photo-\(referencedAttachmentIDs.count + offset + 1)"
                )
            } catch {
                errorMessage = readableMessage(for: error)
            }
        }
    }

    private func importImageFile(at url: URL) {
        guard referencedAttachmentIDs.count < NoteMarkdownImageLimits.maximumImagesPerNote else {
            errorMessage = NoteMarkdownImageError
                .imageLimitReached(limit: NoteMarkdownImageLimits.maximumImagesPerNote)
                .localizedDescription
            return
        }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try Data(contentsOf: url)
            try appendImageAttachment(plaintext: data, fileName: url.lastPathComponent)
        } catch {
            errorMessage = readableMessage(for: error)
        }
    }

    private func appendImageAttachment(plaintext: Data, fileName: String) throws {
        let attachment = try session.addNoteImageAttachment(
            noteID: noteID,
            fileName: fileName,
            plaintext: plaintext,
            existingImageCount: referencedAttachmentIDs.count
        )
        let altText = (fileName as NSString).deletingPathExtension
        let snippet = NoteMarkdownAttachmentReference.imageMarkdown(
            attachmentID: attachment.id,
            altText: altText
        )
        if markdownBody.isEmpty {
            markdownBody = snippet
        } else if markdownBody.hasSuffix("\n\n") {
            markdownBody += snippet
        } else if markdownBody.hasSuffix("\n") {
            markdownBody += "\n" + snippet
        } else {
            markdownBody += "\n\n" + snippet
        }
        _ = session.autosaveNoteDraftIfNeeded()
    }

    private func readableMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(localized: "图片插入失败，请换一张再试。")
    }

    // MARK: 草稿

    private func draftBanner(_ draft: NoteDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("发现未保存的草稿", systemImage: "clock.arrow.circlepath")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.primaryDeep)
            Text("保存于 \(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))，可以恢复继续编辑，或彻底丢弃。")
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("恢复草稿") {
                    title = draft.title
                    markdownBody = draft.body
                    didResolveDraft = true
                    pendingDraft = nil
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                Button("丢弃草稿", role: .destructive) {
                    session.discardNoteDraft(draftID: draft.draftID)
                    if title == draft.title && markdownBody == draft.body {
                        title = ""
                        markdownBody = ""
                    }
                    didResolveDraft = true
                    pendingDraft = nil
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AndroidParityPalette.primaryContainer, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func loadPendingDraftIfNeeded() {
        guard !didResolveDraft, let draft = session.noteDraft(forDraftID: draftID) else {
            return
        }
        if AppNoteDraftPolicy.isBlank(draft.title) && AppNoteDraftPolicy.isBlank(draft.body) {
            session.discardNoteDraft(draftID: draft.draftID)
            return
        }
        pendingDraft = draft
    }
}

// MARK: - 缩略图

private struct AppNoteMarkdownThumbnail: View {
    let attachment: LocalAttachmentMetadata?
    let attachmentID: String
    let session: AppSessionModel

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                AndroidParityPalette.surfaceVariant
                    .overlay {
                        Image(systemName: attachment == nil ? "exclamationmark.triangle" : "photo")
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
            }
        }
        .frame(width: 68, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AndroidParityPalette.outline, lineWidth: 1)
        }
        .task(id: attachmentID) {
            guard let attachment else {
                return
            }
            image = try? AppNoteImageCache.shared.image(for: attachment, session: session)
        }
    }
}

// MARK: - 预览渲染

/// 受限 Markdown 渲染：只渲染解析结果，绝不主动发起网络请求或加载外部图片。
struct AppNoteMarkdownPreview: View {
    let document: NoteMarkdownDocument
    let session: AppSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if document.isEmpty {
                Text("还没有内容，切换到「编辑」开始写 Markdown。")
                    .font(.callout)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            } else {
                ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: NoteMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            Text(attributed(content))
                .font(headingFont(level))
                .bold()
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let content):
            Text(attributed(content))
                .font(.body)
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .bulletItem(let indent, let content):
            listRow(marker: "•", indent: indent, content: content)
        case .numberedItem(let indent, let number, let content):
            listRow(marker: "\(number).", indent: indent, content: content)
        case .quote(let content):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(AndroidParityPalette.primary.opacity(0.5))
                    .frame(width: 3)
                Text(attributed(content))
                    .font(.body)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AndroidParityPalette.surfaceVariant, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .divider:
            Divider()
        case .image(let reference):
            AppNoteMarkdownImageBlock(reference: reference, session: session)
        }
    }

    private func listRow(marker: String, indent: Int, content: [NoteMarkdownInline]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.body.monospacedDigit())
                .foregroundStyle(AndroidParityPalette.textSecondary)
            Text(attributed(content))
                .font(.body)
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(min(max(indent, 0), 4)) * 14)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        case 4: return .subheadline
        default: return .footnote
        }
    }

    private func attributed(_ inlines: [NoteMarkdownInline]) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            result.append(attributed(inline))
        }
        return result
    }

    private func attributed(_ inline: NoteMarkdownInline) -> AttributedString {
        switch inline {
        case .text(let value):
            return AttributedString(value)
        case .strong(let value):
            return styled(value, intent: .stronglyEmphasized)
        case .emphasis(let value):
            return styled(value, intent: .emphasized)
        case .strongEmphasis(let value):
            return styled(value, intent: [.stronglyEmphasized, .emphasized])
        case .code(let value):
            var attributed = AttributedString(value)
            attributed.font = .system(.callout, design: .monospaced)
            attributed.backgroundColor = AndroidParityPalette.surfaceVariant
            return attributed
        case .link(let text, let destination):
            var attributed = AttributedString(text)
            attributed.link = destination
            attributed.underlineStyle = .single
            attributed.foregroundColor = AndroidParityPalette.primaryDeep
            return attributed
        case .image(let reference):
            return AttributedString("🖼 \(reference.altText)")
        case .blockedImage(let text, let address):
            var attributed = AttributedString("🖼 \(text.isEmpty ? address : text)（外部图片已阻止）")
            attributed.foregroundColor = AndroidParityPalette.textSecondary
            return attributed
        }
    }

    private func styled(_ value: String, intent: InlinePresentationIntent) -> AttributedString {
        var attributed = AttributedString(value)
        attributed.inlinePresentationIntent = intent
        return attributed
    }
}

// MARK: - 图片块

private struct AppNoteMarkdownImageBlock: View {
    let reference: NoteMarkdownImageReference
    let session: AppSessionModel

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if didFail {
                placeholder(systemImage: "lock.slash", title: "图片不可用")
            } else {
                placeholder(systemImage: "photo", title: "正在解密图片…")
                    .overlay { ProgressView() }
            }
        }
        .accessibilityLabel(Text(reference.altText.isEmpty ? "笔记图片" : reference.altText))
        .task(id: reference.attachmentID) {
            load()
        }
    }

    private func placeholder(systemImage: String, title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title3)
            Text(title)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .foregroundStyle(AndroidParityPalette.textSecondary)
        .background(AndroidParityPalette.surfaceVariant, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AndroidParityPalette.outline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }

    private func load() {
        if let cached = AppNoteImageCache.shared.cachedImage(for: reference.attachmentID) {
            image = cached
            return
        }
        guard let attachment = session.noteImageAttachment(withID: reference.attachmentID) else {
            didFail = true
            return
        }
        image = try? AppNoteImageCache.shared.image(for: attachment, session: session)
        didFail = image == nil
    }
}
