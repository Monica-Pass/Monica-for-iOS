import Foundation
import MonicaStorage
import XCTest

@testable import Monica

/// 笔记 Markdown + 图片 + 草稿策略的应用层测试。
/// 渲染细节（解析子集）与草稿加密在 MonicaStorage 包的测试里覆盖，这里只测 App 侧策略。
final class MarkdownNoteTests: XCTestCase {
    private let onePixelPNG = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    // MARK: 草稿槽位

    func testDraftIDUsesNoteEntryIDWhenSupported() {
        XCTAssertEqual(AppNoteDraftPolicy.draftID(noteID: "note-123_ab"), "note-123_ab")
        XCTAssertEqual(AppNoteDraftPolicy.draftID(noteID: nil), AppNoteDraftPolicy.newNoteDraftID)
        XCTAssertEqual(AppNoteDraftPolicy.draftID(noteID: ""), AppNoteDraftPolicy.newNoteDraftID)
        XCTAssertEqual(AppNoteDraftPolicy.draftID(noteID: "../escape"), AppNoteDraftPolicy.newNoteDraftID)
        XCTAssertEqual(AppNoteDraftPolicy.draftID(noteID: "has space"), AppNoteDraftPolicy.newNoteDraftID)
    }

    func testShouldSaveDraftOnlyWhenContentDiffers() {
        XCTAssertFalse(AppNoteDraftPolicy.shouldSaveDraft(title: "", body: "  \n", baselineTitle: nil, baselineBody: nil))
        XCTAssertTrue(AppNoteDraftPolicy.shouldSaveDraft(title: "标题", body: "", baselineTitle: nil, baselineBody: nil))
        XCTAssertTrue(AppNoteDraftPolicy.shouldSaveDraft(title: "", body: "正文", baselineTitle: nil, baselineBody: nil))
        XCTAssertFalse(
            AppNoteDraftPolicy.shouldSaveDraft(
                title: "标题",
                body: "正文",
                baselineTitle: "标题",
                baselineBody: "正文"
            )
        )
        XCTAssertTrue(
            AppNoteDraftPolicy.shouldSaveDraft(
                title: "标题",
                body: "正文改了",
                baselineTitle: "标题",
                baselineBody: "正文"
            )
        )
    }

    // MARK: 移除图片引用

    func testRemovingImageReferenceKeepsOtherContent() {
        let attachmentID = "img-1"
        let otherID = "img-2"
        let body = """
        # 旅行笔记

        第一段文字。

        ![海边](monica-attachment://\(attachmentID))

        - 列表项

        ![](monica-attachment://\(otherID))
        """
        let cleaned = AppNoteDraftPolicy.removingImageReferences(attachmentID: attachmentID, from: body)
        XCTAssertFalse(cleaned.contains(NoteMarkdownAttachmentReference.urlPrefix + attachmentID))
        XCTAssertTrue(cleaned.contains("第一段文字。"))
        XCTAssertTrue(cleaned.contains(NoteMarkdownAttachmentReference.urlPrefix + otherID))
        XCTAssertFalse(cleaned.contains("\n\n\n"))
        XCTAssertEqual(
            NoteMarkdownAttachmentReference.attachmentIDs(in: cleaned),
            [otherID]
        )
    }

    func testRemovingUnknownReferenceLeavesBodyUntouched() {
        let body = "没有图片的正文"
        XCTAssertEqual(AppNoteDraftPolicy.removingImageReferences(attachmentID: "missing", from: body), body)
    }

    // MARK: 文件名

    func testSanitizedImageFileNameRejectsTraversalAndFixesExtension() {
        XCTAssertEqual(AppNoteDraftPolicy.sanitizedImageFileName("../../etc/passwd", mediaType: "image/png"), "passwd.png")
        XCTAssertEqual(AppNoteDraftPolicy.sanitizedImageFileName("海边 照片.HEIC", mediaType: "image/heic"), "note-image.heic")
        XCTAssertEqual(AppNoteDraftPolicy.sanitizedImageFileName("", mediaType: "image/jpeg"), "note-image.jpg")
        XCTAssertEqual(AppNoteDraftPolicy.sanitizedImageFileName("photo.png", mediaType: "image/jpeg"), "photo.jpg")
        XCTAssertEqual(AppNoteDraftPolicy.sanitizedImageFileName("photo.png", mediaType: "image/png"), "photo.png")
        let longName = String(repeating: "a", count: 400) + ".png"
        XCTAssertLessThanOrEqual(
            AppNoteDraftPolicy.sanitizedImageFileName(longName, mediaType: "image/png").count,
            105
        )
        let nested = AppNoteDraftPolicy.sanitizedImageFileName("a/b\\c.png", mediaType: "image/png")
        XCTAssertEqual(nested, "c.png")
        XCTAssertFalse(nested.contains("/"))
        XCTAssertFalse(nested.contains("\\"))
    }

    // MARK: 图片上限

    func testImageInspectorAcceptsOnePixelPNG() throws {
        let properties = try NoteMarkdownImageInspector.inspect(onePixelPNG)
        XCTAssertEqual(properties.mediaType, "image/png")
        XCTAssertEqual(properties.byteCount, onePixelPNG.count)
        XCTAssertEqual(properties.pixelWidth, 1)
        XCTAssertEqual(properties.pixelHeight, 1)
    }

    func testImageInspectorRejectsOversizedPayload() {
        let oversized = Data(repeating: 0x00, count: NoteMarkdownImageLimits.maximumBytesPerImage + 1)
        XCTAssertThrowsError(try NoteMarkdownImageInspector.inspect(oversized)) { error in
            guard case .imageTooLarge(let byteCount, let limit) = error as? NoteMarkdownImageError else {
                return XCTFail("expected imageTooLarge, got \(error)")
            }
            XCTAssertEqual(byteCount, oversized.count)
            XCTAssertEqual(limit, NoteMarkdownImageLimits.maximumBytesPerImage)
        }
    }

    func testImageInspectorRejectsUnsupportedFormatAndEmptyData() {
        XCTAssertThrowsError(try NoteMarkdownImageInspector.inspect(Data("not an image".utf8))) { error in
            XCTAssertEqual(error as? NoteMarkdownImageError, .unsupportedFormat)
        }
        XCTAssertThrowsError(try NoteMarkdownImageInspector.inspect(Data())) { error in
            XCTAssertEqual(error as? NoteMarkdownImageError, .emptyImage)
        }
    }

    func testPixelCountLimitIsEnforced() {
        XCTAssertNoThrow(try NoteMarkdownImageLimits.validate(pixelWidth: 4000, pixelHeight: 3000))
        XCTAssertThrowsError(try NoteMarkdownImageLimits.validate(pixelWidth: 4001, pixelHeight: 3000)) { error in
            guard case .tooManyPixels(let pixelCount, let limit) = error as? NoteMarkdownImageError else {
                return XCTFail("expected tooManyPixels, got \(error)")
            }
            XCTAssertEqual(pixelCount, 4001 * 3000)
            XCTAssertEqual(limit, NoteMarkdownImageLimits.maximumPixelCount)
        }
        // 溢出时不能崩溃，要给出可读错误。
        XCTAssertThrowsError(try NoteMarkdownImageLimits.validate(pixelWidth: Int.max, pixelHeight: Int.max))
    }

    func testImageErrorMessagesAreReadable() {
        XCTAssertTrue(
            NoteMarkdownImageError.imageLimitReached(limit: 20).localizedDescription.contains("20")
        )
        XCTAssertTrue(
            NoteMarkdownImageError.imageTooLarge(byteCount: 99, limit: 8)
                .localizedDescription.contains("99")
        )
        XCTAssertFalse(NoteMarkdownImageError.unreadableImage.localizedDescription.isEmpty)
    }

    // MARK: 图片引用解析

    func testAttachmentIDsIgnoreUnsupportedAndDerivedURLs() {
        let body = """
        ![ok](monica-attachment://abc_123)
        ![dup](monica-attachment://abc_123)
        ![bad](monica-attachment://bad id)
        ![remote](https://example.com/tracker.png)
        ![](monica-attachment://x-9)
        """
        XCTAssertEqual(NoteMarkdownAttachmentReference.attachmentIDs(in: body), ["abc_123", "x-9"])
    }

    func testMarkdownDocumentKeepsLocalImagesAndBlocksRemoteOnes() {
        let body = """
        # 标题

        一段**加粗**与`代码`，见[链接](https://example.com/doc)。

        - 列表项

        > 引用

        ```swift
        let x = 1
        ```

        ![本地](monica-attachment://img-1)

        ![追踪](https://tracker.example.com/pixel.png)
        """
        let document = NoteMarkdownDocument.parse(body)
        XCTAssertEqual(document.attachmentIDs, ["img-1"])
        XCTAssertTrue(document.blocks.contains { block in
            if case .image(let reference) = block {
                return reference.attachmentID == "img-1"
            }
            return false
        })
        XCTAssertFalse(document.isEmpty)
        let hasBlockedRemoteImage = document.blocks.contains { block in
            guard case .paragraph(let inlines) = block else {
                return false
            }
            return inlines.contains { inline in
                guard case .blockedImage(_, let address) = inline else {
                    return false
                }
                return address.contains("tracker.example.com")
            }
        }
        XCTAssertTrue(hasBlockedRemoteImage, "外部图片必须降级为 blockedImage，不能被加载")
    }

    // MARK: 草稿存储（应用层路径）

    func testNoteDraftStoreRoundTripWithGeneratedKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-md-note-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteDraftStore(
            directoryURL: directory,
            keyProvider: StaticNoteDraftKeyProvider(key: NoteDraftKeyGenerator.makeKey())
        )
        let draft = NoteDraft(
            draftID: AppNoteDraftPolicy.newNoteDraftID,
            noteID: nil,
            title: "草稿标题",
            body: "![图](monica-attachment://img-1)"
        )
        try store.saveDraft(draft)
        XCTAssertEqual(try store.loadDraft(draftID: draft.draftID), draft)
        XCTAssertTrue(store.draftExists(draftID: draft.draftID))

        // 磁盘上不能出现明文。
        let fileURL = store.fileURL(forDraftID: draft.draftID)
        let raw = try Data(contentsOf: fileURL)
        XCTAssertNil(String(data: raw, encoding: .utf8))
        XCTAssertNil(raw.range(of: Data("草稿标题".utf8)))

        try store.deleteDraft(draftID: draft.draftID)
        XCTAssertFalse(store.draftExists(draftID: draft.draftID))
        XCTAssertNil(try store.loadDraft(draftID: draft.draftID))
    }
}
