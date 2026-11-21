import MonicaStorage
import Photos
import PhotosUI
import SwiftUI
import UIKit

enum IdentityDocumentPhotoSide: String, CaseIterable, Identifiable, Sendable {
    case front
    case back

    var id: String { rawValue }

    /// 附件表没有角色字段，用固定文件名前缀区分正反面；fileName 会随备份导出，升级后仍可识别。
    var fileNamePrefix: String { "identity-\(rawValue)-" }

    var localizedTitle: String {
        switch self {
        case .front: return String(localized: "证件正面")
        case .back: return String(localized: "证件反面")
        }
    }

    var systemImage: String {
        switch self {
        case .front: return "person.text.rectangle"
        case .back: return "rectangle.portrait.and.arrow.right"
        }
    }
}

enum IdentityPhotoError: LocalizedError {
    case tooLarge
    case unreadable
    case encodingFailed
    case plusRequired

    var errorDescription: String? {
        switch self {
        case .tooLarge: return String(localized: "图片过大，请选择 20 MB 以内的图片。")
        case .unreadable: return String(localized: "无法读取所选图片。")
        case .encodingFailed: return String(localized: "图片处理失败，请重新选择。")
        case .plusRequired: return String(localized: "证件照片需要解锁 Plus。")
        }
    }
}

enum IdentityPhotoProcessor {
    static let maximumByteCount = 20 * 1024 * 1024
    static let maximumDimension: CGFloat = 1600

    /// 校验并缩放为 JPEG，避免把原始照片（含 EXIF）直接写进 Vault。
    static func prepare(_ data: Data) throws -> Data {
        guard data.count <= maximumByteCount else { throw IdentityPhotoError.tooLarge }
        guard let image = UIImage(data: data) else { throw IdentityPhotoError.unreadable }
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { throw IdentityPhotoError.unreadable }

        let scale = min(1, maximumDimension / max(sourceSize.width, sourceSize.height))
        let targetSize = CGSize(
            width: max(1, (sourceSize.width * scale).rounded()),
            height: max(1, (sourceSize.height * scale).rounded())
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: 0.82) else {
            throw IdentityPhotoError.encodingFailed
        }
        return jpeg
    }
}

/// 证件正反面照片。编辑态负责选择/替换/删除，详情态按敏感字段开关决定是否显示。
struct IdentityDocumentPhotoSection: View {
    @Bindable var session: AppSessionModel
    let entryID: String
    let allowsEditing: Bool
    let masksPhotos: Bool

    @State private var isPickerPresented = false
    @State private var pickerSide: IdentityDocumentPhotoSide = .front
    @State private var selectedItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var errorMessage: String?

    private var attachments: [LocalAttachmentMetadata] {
        session.attachmentEntries(for: entryID)
    }

    private var hasAnyPhoto: Bool {
        attachments.contains { attachment in
            IdentityDocumentPhotoSide.allCases.contains { attachment.fileName.hasPrefix($0.fileNamePrefix) }
        }
    }

    var body: some View {
        if allowsEditing || hasAnyPhoto {
            AndroidParitySection(title: String(localized: "证件照片")) {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    HStack(alignment: .top, spacing: 12) {
                        photoTile(.front)
                        photoTile(.back)
                    }
                    Text("照片保存在 Vault 加密附件中，不会写入相册或系统缩略图缓存。")
                        .font(.caption2)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    if allowsEditing, !session.isPlusActive {
                        AndroidParityInfoRow(title: "Plus", value: String(localized: "证件照片需要解锁"))
                        Button {
                            Task { try? await session.activatePlusFromResource() }
                        } label: {
                            Label("解锁 Plus", systemImage: "checkmark.seal")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                        .disabled(!session.canActivatePlusFromResource)
                    }
                    if isImporting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在处理照片…")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                        }
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.danger)
                            .accessibilityLabel(Text(errorMessage))
                    }
                }
            }
            .photosPicker(
                isPresented: $isPickerPresented,
                selection: $selectedItem,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: selectedItem) { _, newItem in
                guard let newItem else { return }
                importPhoto(newItem, side: pickerSide)
            }
        }
    }

    private func attachment(for side: IdentityDocumentPhotoSide) -> LocalAttachmentMetadata? {
        attachments.first { $0.fileName.hasPrefix(side.fileNamePrefix) }
    }

    @ViewBuilder
    private func photoTile(_ side: IdentityDocumentPhotoSide) -> some View {
        let attachment = attachment(for: side)
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AndroidParityPalette.background)
                if let attachment {
                    if masksPhotos {
                        VStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                                .font(.title3.weight(.semibold))
                            Text("已隐藏")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    } else {
                        IdentityPhotoThumbnail(session: session, attachment: attachment)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: side.systemImage)
                            .font(.title3.weight(.semibold))
                        Text("未添加")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                }
            }
            .frame(height: 112)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AndroidParityPalette.outline, lineWidth: 1.2)
            }

            Text(side.localizedTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)

            if allowsEditing {
                HStack(spacing: 8) {
                    Button {
                        pickerSide = side
                        selectedItem = nil
                        isPickerPresented = true
                    } label: {
                        Label(attachment == nil ? "添加照片" : "替换照片", systemImage: "photo.badge.plus")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(AndroidParityPalette.primary)
                    .disabled(isImporting)

                    if attachment != nil {
                        Button(role: .destructive) {
                            deletePhoto(side)
                        } label: {
                            Label("删除照片", systemImage: "trash")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .disabled(isImporting)
                    }
                }
            } else if let attachment, !masksPhotos {
                Button {
                    try? session.presentAttachmentQuickLookPreview(attachment)
                } label: {
                    Label("查看大图", systemImage: "eye")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AndroidParityPalette.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func importPhoto(_ item: PhotosPickerItem, side: IdentityDocumentPhotoSide) {
        guard allowsEditing else { return }
        guard session.isPlusActive else {
            errorMessage = IdentityPhotoError.plusRequired.localizedDescription
            selectedItem = nil
            return
        }
        isImporting = true
        errorMessage = nil
        Task { @MainActor in
            defer {
                isImporting = false
                selectedItem = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw IdentityPhotoError.unreadable
                }
                let prepared = try IdentityPhotoProcessor.prepare(data)
                let existing = attachment(for: side)
                _ = try session.addLocalAttachmentContent(
                    entryID: entryID,
                    fileName: "\(side.fileNamePrefix)\(UUID().uuidString).jpg",
                    mediaType: "image/jpeg",
                    plaintext: prepared,
                    source: "ios-identity-photo"
                )
                if let existing {
                    try? session.deleteAttachmentEntry(existing)
                }
                errorMessage = nil
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func deletePhoto(_ side: IdentityDocumentPhotoSide) {
        guard let attachment = attachment(for: side) else { return }
        do {
            try session.deleteAttachmentEntry(attachment)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct IdentityPhotoThumbnail: View {
    let session: AppSessionModel
    let attachment: LocalAttachmentMetadata

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if didFail {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title3.weight(.semibold))
                    Text("无法读取")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(AndroidParityPalette.textSecondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: attachment.id) {
            guard image == nil else { return }
            do {
                let data = try session.attachmentPlaintext(attachment)
                guard let decoded = UIImage(data: data) else {
                    didFail = true
                    return
                }
                image = decoded
            } catch {
                didFail = true
            }
        }
    }
}
