import Foundation
import MonicaStorage
import Testing

@Suite("笔记列表摘要与图片角标")
struct NoteListSummaryTests {
    // MARK: 摘要

    @Test func summaryStripsBlockAndInlineMarkdown() {
        let body = """
        # 会议记录

        今天讨论了 **发布节奏**，以及 [路线图](https://example.com/roadmap)。

        - 第一项
        - 第二项
        """

        #expect(NoteListSummary.plainText(from: body) == "会议记录 今天讨论了 发布节奏，以及 路线图。 第一项 第二项")
    }

    @Test func summaryKeepsInlineCodeTextAndSkipsFencedCodeBlocks() {
        let body = """
        查看 `note.md` 后确认。

        ```markdown
        # 代码块里的标题
        ![](monica-attachment://inside-code)
        ```

        收尾。
        """

        let summary = NoteListSummary.summarize(body)
        #expect(summary.plainText == "查看 note.md 后确认。 收尾。")
        #expect(summary.imageAttachmentIDs.isEmpty)
    }

    @Test func summaryIsTruncatedAtTheCharacterLimit() {
        let body = "abcdefghij"

        #expect(NoteListSummary.plainText(from: body, limit: 5) == "abcde…")
        // 正好等于上限时不加省略号。
        #expect(NoteListSummary.plainText(from: body, limit: 10) == "abcdefghij")
        #expect(NoteListSummary.plainText(from: body, limit: 0) == "")
    }

    @Test func summaryCollapsesWhitespaceAcrossLines() {
        #expect(NoteListSummary.plainText(from: "  第一行  \n\n   第二行\t带制表符  ") == "第一行 第二行 带制表符")
    }

    @Test func summaryOfEmptyBodyIsEmpty() {
        let summary = NoteListSummary.summarize("")
        #expect(summary.plainText.isEmpty)
        #expect(summary.imageAttachmentIDs.isEmpty)
        #expect(summary.imageAttachmentCount == 0)
        #expect(summary.hasImageAttachments == false)
    }

    // MARK: 图片角标

    @Test func noteWithoutImagesHasNoBadge() {
        let body = "只有文字，没有图片。\n\n[普通链接](https://example.com/photo.png)"

        #expect(NoteListSummary.imageAttachmentIDs(in: body).isEmpty)
        #expect(NoteListSummary.imageAttachmentCount(in: body) == 0)
    }

    @Test func singleImageAttachmentIsCounted() {
        let body = "周末拍的照片：\n\n![猫](monica-attachment://photo-cat)"

        #expect(NoteListSummary.imageAttachmentIDs(in: body) == ["photo-cat"])
        #expect(NoteListSummary.imageAttachmentCount(in: body) == 1)
        // 图片附件的 URL 不能漏进摘要，替代文字可以。
        #expect(NoteListSummary.plainText(from: body) == "周末拍的照片： 猫")
    }

    @Test func multipleImageAttachmentsAreOrderedAndDeduplicated() {
        let body = """
        ![](monica-attachment://one)
        ![](monica-attachment://two)
        中间文字
        ![](monica-attachment://one)
        """

        #expect(NoteListSummary.imageAttachmentIDs(in: body) == ["one", "two"])
        #expect(NoteListSummary.imageAttachmentCount(in: body) == 2)
    }

    @Test func imageMarkdownInsideFencedCodeBlockIsNotCounted() {
        let body = """
        正文

        ~~~
        ![示例](monica-attachment://code-fence)
        ~~~

        结尾
        """

        #expect(NoteListSummary.imageAttachmentCount(in: body) == 0)
        #expect(NoteListSummary.plainText(from: body) == "正文 结尾")
    }

    @Test func imageMarkdownInsideInlineCodeIsNotCounted() {
        let body = "写作 `![示例](monica-attachment://inline-code)` 与 ![真图](monica-attachment://real-photo)"

        #expect(NoteListSummary.imageAttachmentIDs(in: body) == ["real-photo"])
        #expect(NoteListSummary.plainText(from: body) == "写作 ![示例](monica-attachment://inline-code) 与 真图")
    }

    @Test func escapedImageMarkdownIsNotCounted() {
        let body = "\\![示例](monica-attachment://escaped)"

        #expect(NoteListSummary.imageAttachmentIDs(in: body).isEmpty)
    }

    @Test func imagesWithUnsupportedAddressesAreNotCounted() {
        let body = """
        ![外部](https://example.com/cat.png)
        ![坏 id](monica-attachment://bad$id)
        ![合法](monica-attachment://ok_id-1)
        """

        #expect(NoteListSummary.imageAttachmentIDs(in: body) == ["ok_id-1"])
    }

    @Test func imageAttachmentCountMatchesAttachmentIDsHelper() {
        let body = "A\n\n![](monica-attachment://alpha)\n\nB\n\n![](monica-attachment://beta)\n![](monica-attachment://alpha)"

        #expect(NoteListSummary.imageAttachmentIDs(in: body)
            == NoteMarkdownAttachmentReference.attachmentIDs(in: body))
        #expect(NoteListSummary.imageAttachmentCount(in: body) == 2)
    }
}
