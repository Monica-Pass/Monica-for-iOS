import Testing
import Foundation
import MonicaStorage

@Suite("笔记 Markdown 子集")
struct NoteMarkdownTests {
    // MARK: 块级

    @Test func parsesATXHeadingsAndTrimsClosingHashes() {
        let document = NoteMarkdownDocument.parse("""
        # 一级标题
        ## 二级 ##
        ###### 六级 ######
        ####### 七个井号不算标题
        """)

        #expect(document.blocks.count == 4)
        guard case .heading(let firstLevel, let firstContent) = document.blocks[0] else {
            Issue.record("第一个块应为标题")
            return
        }
        #expect(firstLevel == 1)
        #expect(firstContent == [.text("一级标题")])
        guard case .heading(let secondLevel, let secondContent) = document.blocks[1] else {
            Issue.record("第二个块应为标题")
            return
        }
        #expect(secondLevel == 2)
        #expect(secondContent == [.text("二级")])
        guard case .heading(let thirdLevel, _) = document.blocks[2] else {
            Issue.record("第三个块应为标题")
            return
        }
        #expect(thirdLevel == 6)
        // 7 个 # 不是合法标题，按段落处理。
        guard case .paragraph = document.blocks[3] else {
            Issue.record("第四个块应为段落")
            return
        }
    }

    @Test func parsesBulletsOrderedItemsAndIndent() {
        let document = NoteMarkdownDocument.parse("""
        - 第一项
          - 缩进一项
        1. 有序一
        2) 有序二
        200. 大数字
        """)

        let blocks = document.blocks
        #expect(blocks.count == 5)
        guard case .bulletItem(let indent, let first) = blocks[0] else {
            Issue.record("第一个块应为无序列表")
            return
        }
        #expect(indent == 0)
        #expect(first == [.text("第一项")])
        guard case .bulletItem(let nestedIndent, _) = blocks[1] else {
            Issue.record("第二个块应为缩进无序列表")
            return
        }
        #expect(nestedIndent == 1)
        guard case .numberedItem(let orderIndent, let number, let content) = blocks[2] else {
            Issue.record("第三个块应为有序列表")
            return
        }
        #expect(orderIndent == 0)
        #expect(number == 1)
        #expect(content == [.text("有序一")])
        guard case .numberedItem(_, let secondNumber, _) = blocks[3] else {
            Issue.record("第四个块应为有序列表")
            return
        }
        #expect(secondNumber == 2)
        guard case .numberedItem(_, let bigNumber, _) = blocks[4] else {
            Issue.record("第五个块应为有序列表")
            return
        }
        #expect(bigNumber == 200)
    }

    @Test func mergesQuoteLinesAndParsesInline() {
        let document = NoteMarkdownDocument.parse("""
        > 引用第一行
        > 引用 **第二行**
        """)

        #expect(document.blocks.count == 1)
        guard case .quote(let content) = document.blocks[0] else {
            Issue.record("应为引用块")
            return
        }
        #expect(content == [.text("引用第一行 引用 "), .strong("第二行")])
    }

    @Test func parsesFencedCodeBlockAndKeepsContentVerbatim() {
        let document = NoteMarkdownDocument.parse("""
        前面一段

        ```swift
        let value = 1
        # 不是标题
        ```

        后面一段
        """)

        #expect(document.blocks.count == 3)
        guard case .codeBlock(let language, let code) = document.blocks[1] else {
            Issue.record("中间应为代码块")
            return
        }
        #expect(language == "swift")
        #expect(code == "let value = 1\n# 不是标题")
    }

    @Test func unclosedFenceConsumesRestOfDocument() {
        let document = NoteMarkdownDocument.parse("```\n未闭合\n还是代码")
        guard case .codeBlock(let language, let code) = document.blocks[0] else {
            Issue.record("应为代码块")
            return
        }
        #expect(language == nil)
        #expect(code == "未闭合\n还是代码")
    }

    @Test func recognizesDividerAndParagraphInterruption() {
        let document = NoteMarkdownDocument.parse("""
        第一段
        紧跟的一行
        # 没有空行的标题
        ---
        结尾
        """)

        #expect(document.blocks.count == 4)
        guard case .paragraph(let first) = document.blocks[0] else {
            Issue.record("应为段落")
            return
        }
        // 段落内的软换行按 CommonMark 合并为空格。
        #expect(first == [.text("第一段 紧跟的一行")])
        guard case .heading(let level, _) = document.blocks[1] else {
            Issue.record("应为标题")
            return
        }
        #expect(level == 1)
        #expect(document.blocks[2] == .divider)
        guard case .paragraph(let last) = document.blocks[3] else {
            Issue.record("应为段落")
            return
        }
        #expect(last == [.text("结尾")])
    }

    // MARK: 行内

    @Test func parsesEmphasisCodeAndEscapes() {
        let document = NoteMarkdownDocument.parse(
            "普通 **粗体** 与 *斜体* 还有 ***粗斜体***、`let x = 1`、snake_case、\\*不是斜体\\*"
        )
        guard case .paragraph(let content) = document.blocks[0] else {
            Issue.record("应为段落")
            return
        }
        #expect(content == [
            .text("普通 "),
            .strong("粗体"),
            .text(" 与 "),
            .emphasis("斜体"),
            .text(" 还有 "),
            .strongEmphasis("粗斜体"),
            .text("、"),
            .code("let x = 1"),
            .text("、snake_case、*不是斜体*")
        ])
    }

    @Test func unmatchedMarkersStayLiteral() {
        let document = NoteMarkdownDocument.parse("**没有闭合 与 *单独星号 与 `孤立反引号")
        guard case .paragraph(let content) = document.blocks[0] else {
            Issue.record("应为段落")
            return
        }
        #expect(content == [.text("**没有闭合 与 *单独星号 与 `孤立反引号")])
    }

    @Test func allowsOnlySafeLinkSchemes() {
        let document = NoteMarkdownDocument.parse("""
        [官网](https://example.com/path?q=1) [邮件](mailto:a@example.com) [脚本](javascript:alert(1)) [文件](file:///etc/passwd)
        """)
        guard case .paragraph(let content) = document.blocks[0] else {
            Issue.record("应为段落")
            return
        }
        let links = content.compactMap { inline -> (text: String, url: URL)? in
            if case .link(let text, let url) = inline {
                return (text, url)
            }
            return nil
        }
        #expect(links.count == 2)
        #expect(links.first?.text == "官网")
        #expect(links.first?.url.absoluteString == "https://example.com/path?q=1")
        #expect(links.last?.url.scheme == "mailto")

        // 不支持的 scheme 原样显示，不生成可点击链接。
        let texts = content.compactMap { inline -> String? in
            if case .text(let value) = inline {
                return value
            }
            return nil
        }
        #expect(texts.contains("[脚本](javascript:alert(1)) "))
        #expect(texts.contains("[文件](file:///etc/passwd)"))
        #expect(links.allSatisfy { $0.url.scheme == "https" || $0.url.scheme == "mailto" })
    }

    // MARK: 图片与安全

    @Test func parsesVaultImageAsBlock() {
        let attachmentID = "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"
        let document = NoteMarkdownDocument.parse("""

        ![猫咪](monica-attachment://\(attachmentID))

        """)

        #expect(document.blocks.count == 1)
        guard case .image(let reference) = document.blocks[0] else {
            Issue.record("独占一段的附件图片应为图片块")
            return
        }
        #expect(reference.attachmentID == attachmentID)
        #expect(reference.altText == "猫咪")
        #expect(document.attachmentIDs == [attachmentID])
    }

    @Test func blocksEveryExternalImageAddress() {
        let document = NoteMarkdownDocument.parse(
            "![追踪像素](https://tracker.example.com/pixel.png)\n![本地](file:///etc/passwd)\n![数据](data:image/png;base64,AAAA)"
        )
        #expect(document.attachmentIDs.isEmpty)
        for block in document.blocks {
            guard case .paragraph(let content) = block else {
                Issue.record("应为段落块")
                return
            }
            for inline in content {
                switch inline {
                case .blockedImage:
                    break
                case .text, .strong, .emphasis, .strongEmphasis, .code, .link:
                    // 空白或换行文本可以接受。
                    break
                case .image:
                    Issue.record("外部图片绝不能被解析成可加载图片")
                }
            }
        }
        // 第一段必须是 blockedImage，且保留原始地址仅供界面提示，不产生 URL。
        guard case .paragraph(let firstParagraph) = document.blocks[0] else {
            Issue.record("应为段落块")
            return
        }
        #expect(firstParagraph.contains(.blockedImage(text: "追踪像素", address: "https://tracker.example.com/pixel.png")))
    }

    @Test func degradesInlineImageToText() {
        let attachmentID = "ABCDEF"
        let document = NoteMarkdownDocument.parse("文字 ![图](monica-attachment://\(attachmentID)) 结尾")
        guard case .paragraph(let content) = document.blocks[0] else {
            Issue.record("应为段落")
            return
        }
        #expect(content == [.text("文字 "), .text("🖼 图"), .text(" 结尾")])
        #expect(document.attachmentIDs == [attachmentID])
    }

    @Test func attachmentIDsAreDeduplicatedAndOrdered() {
        let body = """
        ![a](monica-attachment://one)
        ![b](monica-attachment://two)
        ![a2](monica-attachment://one)
        ![坏](monica-attachment://../etc)
        """
        #expect(NoteMarkdownAttachmentReference.attachmentIDs(in: body) == ["one", "two"])
    }

    @Test func rejectsUnsafeAttachmentIdentifiers() {
        #expect(NoteMarkdownAttachmentReference.isSupportedAttachmentID("A1B2-C3_D4"))
        #expect(NoteMarkdownAttachmentReference.attachmentID(from: "monica-attachment://A1B2-C3_D4") == "A1B2-C3_D4")
        #expect(NoteMarkdownAttachmentReference.attachmentID(from: "monica-attachment://../secret") == nil)
        #expect(NoteMarkdownAttachmentReference.attachmentID(from: "monica-attachment://a/b") == nil)
        #expect(NoteMarkdownAttachmentReference.attachmentID(from: "http://example.com/a.png") == nil)
        #expect(NoteMarkdownAttachmentReference.attachmentID(from: "monica-attachment://") == nil)
        #expect(!NoteMarkdownAttachmentReference.isSupportedAttachmentID(""))
        #expect(!NoteMarkdownAttachmentReference.isSupportedAttachmentID(String(repeating: "a", count: 129)))
        #expect(NoteMarkdownAttachmentReference.imageMarkdown(attachmentID: "bad id") == "")
    }

    @Test func sanitizesAltTextWhenBuildingImageMarkdown() {
        let markdown = NoteMarkdownAttachmentReference.imageMarkdown(
            attachmentID: "okid",
            altText: "换行\n与[方括号]和(圆括号)"
        )
        #expect(markdown == "![换行 与方括号和圆括号](monica-attachment://okid)")

        let longText = String(repeating: "长", count: 500)
        let sanitized = NoteMarkdownAttachmentReference.sanitizedAltText(longText)
        #expect(sanitized.count == NoteMarkdownImageLimits.maximumAltTextLength)
    }

    @Test func parsesGarbageWithoutCrashing() {
        let inputs = [
            "",
            "![",
            "![alt](",
            "[",
            "```",
            "***",
            "\u{0}控制字符",
            "😀 emoji ![x](monica-attachment://ok) 😀"
        ]
        for input in inputs {
            _ = NoteMarkdownDocument.parse(input)
        }
    }

    // MARK: 图片限制

    @Test func validatesPixelBudget() throws {
        try NoteMarkdownImageLimits.validate(pixelWidth: 100, pixelHeight: 100)
        #expect(throws: NoteMarkdownImageError.tooManyPixels(
            pixelCount: 5000 * 5000,
            limit: NoteMarkdownImageLimits.maximumPixelCount
        )) {
            try NoteMarkdownImageLimits.validate(pixelWidth: 5000, pixelHeight: 5000)
        }
        #expect(throws: NoteMarkdownImageError.unreadableImage) {
            try NoteMarkdownImageLimits.validate(pixelWidth: 0, pixelHeight: 10)
        }
    }

    @Test func inspectsPNGMetadata() throws {
        let data = try #require(Data(base64Encoded: Self.onePixelPNG))
        let properties = try NoteMarkdownImageInspector.inspect(data)
        #expect(properties.mediaType == "image/png")
        #expect(properties.pixelWidth == 1)
        #expect(properties.pixelHeight == 1)
        #expect(properties.byteCount == data.count)
    }

    @Test func rejectsEmptyOversizedAndCorruptImages() throws {
        #expect(throws: NoteMarkdownImageError.emptyImage) {
            try NoteMarkdownImageInspector.inspect(Data())
        }

        let oversized = Data(count: NoteMarkdownImageLimits.maximumBytesPerImage + 1)
        #expect(throws: NoteMarkdownImageError.imageTooLarge(
            byteCount: oversized.count,
            limit: NoteMarkdownImageLimits.maximumBytesPerImage
        )) {
            try NoteMarkdownImageInspector.inspect(oversized)
        }

        #expect(throws: NoteMarkdownImageError.unreadableImage) {
            try NoteMarkdownImageInspector.inspect(Data([0x89, 0x50, 0x4E, 0x47]))
        }
    }

    @Test func rejectsUnsupportedImageFormat() throws {
        // 1x1 24 位 BMP：ImageIO 能读，但不在支持的图片格式白名单里。
        var bmp = Data()
        bmp.append(contentsOf: [0x42, 0x4D])                       // BM
        bmp.append(contentsOf: [58, 0, 0, 0])                      // 文件大小
        bmp.append(contentsOf: [0, 0, 0, 0])
        bmp.append(contentsOf: [54, 0, 0, 0])                      // 像素数据偏移
        bmp.append(contentsOf: [40, 0, 0, 0])                      // DIB 头大小
        bmp.append(contentsOf: [1, 0, 0, 0])                       // 宽
        bmp.append(contentsOf: [1, 0, 0, 0])                       // 高
        bmp.append(contentsOf: [1, 0])                             // 平面数
        bmp.append(contentsOf: [24, 0])                            // 位深
        bmp.append(contentsOf: [0, 0, 0, 0])                       // 无压缩
        bmp.append(contentsOf: [0, 0, 0, 0])                       // 图像大小
        bmp.append(contentsOf: [0, 0, 0, 0])
        bmp.append(contentsOf: [0, 0, 0, 0])
        bmp.append(contentsOf: [0, 0, 0, 0])
        bmp.append(contentsOf: [0, 0, 0, 0])                       // 填充到 54 字节
        bmp.append(contentsOf: [0, 0, 0, 0])                       // 1 像素 + 行填充

        #expect(throws: NoteMarkdownImageError.unsupportedFormat) {
            try NoteMarkdownImageInspector.inspect(bmp)
        }
    }

    @Test func resolvesMediaTypeFromFileExtension() {
        #expect(NoteMarkdownImageInspector.mediaType(forFileExtension: "PNG") == "image/png")
        #expect(NoteMarkdownImageInspector.mediaType(forFileExtension: "jpg") == "image/jpeg")
        #expect(NoteMarkdownImageInspector.mediaType(forFileExtension: "") == "application/octet-stream")
    }

    /// 1 × 1 透明 PNG。
    static let onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
}
