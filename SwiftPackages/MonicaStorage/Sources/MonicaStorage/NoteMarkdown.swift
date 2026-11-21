//
//  NoteMarkdown.swift
//  MonicaStorage
//
//  笔记 Markdown 的受限解析器。
//
//  设计目标：
//  - 零第三方依赖，只用 Foundation / ImageIO，保证 iOS 17 与 macOS 13 都能跑；
//  - 明确只支持 CommonMark 的一个子集：ATX 标题、无序/有序列表、引用、围栏代码块、
//    分隔线、段落、粗体、斜体、粗斜体、行内代码、链接、反斜杠转义；
//  - 图片只允许引用保险库内的附件（`monica-attachment://<attachmentID>`）。
//    任何外部图片地址（http/https/data/file/相对路径……）都不会被网络加载，
//    解析结果为 `blockedImage`，界面只能把它渲染成不可点击的占位符，
//    因此含追踪像素的 Markdown 不会自动发起请求。
//  - 不支持的写法按字面量显示，绝不抛错、绝不崩溃。
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 附件图片引用

/// 笔记 Markdown 引用保险库附件图片的唯一受支持写法。
///
/// ```markdown
/// ![猫咪](monica-attachment://2F0B3C7E-....)
/// ```
///
/// 只有 `monica-attachment://` 加合法附件 ID 才会被当作图片；其余地址一律视为被阻止的外部资源。
public enum NoteMarkdownAttachmentReference {
    /// 附件图片地址使用的私有 scheme。
    public static let scheme = "monica-attachment"

    /// `monica-attachment://` 前缀。
    public static let urlPrefix = "monica-attachment://"

    /// 附件 ID 允许的最大长度。
    public static let maximumAttachmentIDLength = 128

    /// 生成附件图片地址。
    public static func url(forAttachmentID attachmentID: String) -> String {
        "\(urlPrefix)\(attachmentID)"
    }

    /// 校验附件 ID：只允许 ASCII 字母、数字、`-`、`_`，长度不超过上限。
    ///
    /// 严格白名单可以避免把 `../`、`%2F`、换行等字符写进正文或解密路径。
    public static func isSupportedAttachmentID(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= maximumAttachmentIDLength else {
            return false
        }
        return trimmed.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }

    /// 从 Markdown 图片地址中取出附件 ID；不是受支持的附件地址时返回 nil。
    public static func attachmentID(from destination: String) -> String? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(urlPrefix) else {
            return nil
        }
        let rawID = String(trimmed.dropFirst(urlPrefix.count))
        guard isSupportedAttachmentID(rawID) else {
            return nil
        }
        return rawID
    }

    /// 生成一段可直接插入正文的附件图片 Markdown。
    public static func imageMarkdown(attachmentID: String, altText: String = "") -> String {
        guard isSupportedAttachmentID(attachmentID) else {
            return ""
        }
        return "![\(sanitizedAltText(altText))](\(url(forAttachmentID: attachmentID)))"
    }

    /// 清理替代文本：去掉会破坏 Markdown 结构的字符，压平换行并截断。
    public static func sanitizedAltText(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        for character in ["[", "]", "(", ")", "\\"] {
            text = text.replacingOccurrences(of: character, with: "")
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.count > NoteMarkdownImageLimits.maximumAltTextLength {
            text = String(text.prefix(NoteMarkdownImageLimits.maximumAltTextLength))
        }
        return text
    }

    /// 按出现顺序返回正文里引用到的、去重后的附件 ID。
    ///
    /// 该扫描只看原始文本，不受段内降级影响：即使图片引用嵌在文字中间，
    /// 它仍然算“被引用”，保存后可以把之前游离的附件重新挂到笔记上。
    public static func attachmentIDs(in body: String) -> [String] {
        let characters = Array(body)
        var found: [String] = []
        var index = 0
        while index + 1 < characters.count {
            guard characters[index] == "!", characters[index + 1] == "[" else {
                index += 1
                continue
            }
            if let scan = scanBracketDestination(bracketIndex: index + 1, in: characters),
               let attachmentID = attachmentID(from: scan.destination),
               !found.contains(attachmentID) {
                found.append(attachmentID)
                index = scan.endIndex
            } else {
                index += 1
            }
        }
        return found
    }

    // MARK: 扫描工具（模块内部，行内解析器共用）

    /// 从 `![` 的 `!` 位置扫描图片语法。
    static func scanImage(
        at index: Int,
        in characters: [Character]
    ) -> (altText: String, destination: String, endIndex: Int)? {
        guard characters.indices.contains(index), characters[index] == "!" else {
            return nil
        }
        guard let scan = scanBracketDestination(bracketIndex: index + 1, in: characters) else {
            return nil
        }
        return (scan.label, scan.destination, scan.endIndex)
    }

    /// 从 `[` 位置扫描 `[label](destination)`，不支持嵌套方括号。
    static func scanBracketDestination(
        bracketIndex: Int,
        in characters: [Character]
    ) -> (label: String, destination: String, endIndex: Int)? {
        guard characters.indices.contains(bracketIndex), characters[bracketIndex] == "[" else {
            return nil
        }
        var cursor = bracketIndex + 1
        var label = ""
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "\\", cursor + 1 < characters.count {
                label.append(characters[cursor + 1])
                cursor += 2
                continue
            }
            if character == "]", cursor + 1 < characters.count, characters[cursor + 1] == "(" {
                var destinationCursor = cursor + 2
                var destination = ""
                while destinationCursor < characters.count, characters[destinationCursor] != ")" {
                    let candidate = characters[destinationCursor]
                    if candidate == "\n" || candidate == "\r" {
                        return nil
                    }
                    destination.append(candidate)
                    destinationCursor += 1
                }
                guard destinationCursor < characters.count else {
                    return nil
                }
                return (label, destination, destinationCursor + 1)
            }
            if character == "\n" || character == "\r" {
                return nil
            }
            label.append(character)
            cursor += 1
        }
        return nil
    }
}

// MARK: - 文档模型

/// 一张引用保险库附件的图片。
public struct NoteMarkdownImageReference: Sendable, Equatable, Hashable {
    public let attachmentID: String
    public let altText: String

    public init(attachmentID: String, altText: String = "") {
        self.attachmentID = attachmentID
        self.altText = altText
    }

    /// 该引用对应的 Markdown 文本。
    public var markdown: String {
        NoteMarkdownAttachmentReference.imageMarkdown(attachmentID: attachmentID, altText: altText)
    }
}

/// 一段行内内容。刻意不做嵌套，`**粗体里的 *斜体***` 会按最外层样式整体显示。
public enum NoteMarkdownInline: Sendable, Equatable {
    case text(String)
    case strong(String)
    case emphasis(String)
    case strongEmphasis(String)
    case code(String)
    case link(text: String, destination: URL)
    /// 保险库内的加密图片。
    case image(NoteMarkdownImageReference)
    /// 被阻止加载的外部图片：只保留文字，绝不请求网络。
    case blockedImage(text: String, address: String)
}

/// 一个块级元素。
public enum NoteMarkdownBlock: Sendable, Equatable {
    case heading(level: Int, content: [NoteMarkdownInline])
    case paragraph([NoteMarkdownInline])
    case bulletItem(indent: Int, content: [NoteMarkdownInline])
    case numberedItem(indent: Int, number: Int, content: [NoteMarkdownInline])
    case quote([NoteMarkdownInline])
    case codeBlock(language: String?, code: String)
    case divider
    /// 独占一段的保险库图片。
    case image(NoteMarkdownImageReference)
}

/// 解析结果。
public struct NoteMarkdownDocument: Sendable, Equatable {
    public let blocks: [NoteMarkdownBlock]
    /// 正文引用到的附件 ID（去重、保序）。
    public let attachmentIDs: [String]

    public init(blocks: [NoteMarkdownBlock], attachmentIDs: [String] = []) {
        self.blocks = blocks
        self.attachmentIDs = attachmentIDs
    }

    public var isEmpty: Bool {
        blocks.isEmpty
    }

    /// 解析 Markdown 子集。永不抛错：不认识的语法按字面量返回。
    public static func parse(_ source: String) -> NoteMarkdownDocument {
        NoteMarkdownDocument(
            blocks: NoteMarkdownParser.parseBlocks(source),
            attachmentIDs: NoteMarkdownAttachmentReference.attachmentIDs(in: source)
        )
    }
}

// MARK: - 块级解析器

enum NoteMarkdownParser {
    static let escapableCharacters: Set<Character> = [
        "\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "-", ".", "!", ">", "|", "~"
    ]

    static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    static func parseBlocks(_ source: String) -> [NoteMarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var blocks: [NoteMarkdownBlock] = []
        var paragraphLines: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else {
                return
            }
            let text = paragraphLines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            paragraphLines.removeAll(keepingCapacity: true)
            guard !text.isEmpty else {
                return
            }
            let inlines = parseInline(text)
            if inlines.count == 1, case .image(let reference) = inlines[0] {
                blocks.append(.image(reference))
            } else if inlines.contains(where: { inline in
                if case .image = inline { return true }
                return false
            }) {
                // 图片夹在文字中间时，SwiftUI 无法把 Image 塞进 Text，降级成占位文字。
                blocks.append(.paragraph(inlines.map(inlineImageAsText)))
            } else {
                blocks.append(.paragraph(inlines))
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let fence = fenceMarker(trimmed) {
                flushParagraph()
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if isClosingFence(candidate, character: fence.character, count: fence.count) {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.codeBlock(language: fence.language, code: codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = headingContent(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, content: parseInline(heading.content)))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else {
                        break
                    }
                    var text = String(candidate.dropFirst())
                    if text.hasPrefix(" ") {
                        text.removeFirst()
                    }
                    let cleaned = text.trimmingCharacters(in: .whitespaces)
                    if !cleaned.isEmpty {
                        quoteLines.append(cleaned)
                    }
                    index += 1
                }
                blocks.append(.quote(parseInline(quoteLines.joined(separator: " "))))
                continue
            }

            if let bullet = bulletContent(line) {
                flushParagraph()
                blocks.append(.bulletItem(indent: bullet.indent, content: parseInline(bullet.content)))
                index += 1
                continue
            }

            if let ordered = orderedContent(line) {
                flushParagraph()
                blocks.append(.numberedItem(indent: ordered.indent, number: ordered.number, content: parseInline(ordered.content)))
                index += 1
                continue
            }

            if !paragraphLines.isEmpty, startsBlock(trimmed) {
                flushParagraph()
            }
            paragraphLines.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    // MARK: 块级识别

    private static func inlineImageAsText(_ inline: NoteMarkdownInline) -> NoteMarkdownInline {
        if case .image(let reference) = inline {
            let altText = reference.altText.trimmingCharacters(in: .whitespaces)
            return .text(altText.isEmpty ? "🖼" : "🖼 \(altText)")
        }
        return inline
    }

    private static func startsBlock(_ trimmed: String) -> Bool {
        fenceMarker(trimmed) != nil
            || headingContent(trimmed) != nil
            || isDivider(trimmed)
            || trimmed.hasPrefix(">")
            || bulletContent(trimmed) != nil
            || orderedContent(trimmed) != nil
    }

    private struct FenceMarker {
        let character: Character
        let count: Int
        let language: String?
    }

    private static func fenceMarker(_ trimmed: String) -> FenceMarker? {
        guard let first = trimmed.first, first == "`" || first == "~" else {
            return nil
        }
        var count = 0
        for character in trimmed {
            guard character == first else {
                break
            }
            count += 1
        }
        guard count >= 3 else {
            return nil
        }
        let info = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        let language = info.split(separator: " ").first.map(String.init)
        return FenceMarker(character: first, count: count, language: (language?.isEmpty ?? true) ? nil : language)
    }

    private static func isClosingFence(_ trimmed: String, character: Character, count: Int) -> Bool {
        guard !trimmed.isEmpty else {
            return false
        }
        let markerCount = trimmed.prefix(while: { $0 == character }).count
        guard markerCount >= count else {
            return false
        }
        return trimmed.dropFirst(markerCount).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func headingContent(_ trimmed: String) -> (level: Int, content: String)? {
        guard trimmed.hasPrefix("#") else {
            return nil
        }
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard level <= 6, level > 0 else {
            return nil
        }
        let remainder = trimmed.dropFirst(level)
        guard remainder.isEmpty || remainder.first == " " || remainder.first == "\t" else {
            return nil
        }
        var content = remainder.trimmingCharacters(in: .whitespaces)
        // 去掉 CommonMark 允许的行尾闭合 #（前面必须有空格）。
        if let lastNonHash = content.lastIndex(where: { $0 != "#" }) {
            let hashRunStart = content.index(after: lastNonHash)
            if hashRunStart < content.endIndex, content[lastNonHash] == " " {
                content = String(content[..<lastNonHash]).trimmingCharacters(in: .whitespaces)
            }
        }
        return (level, content)
    }

    private static func isDivider(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "-" || first == "*" || first == "_" else {
            return false
        }
        guard trimmed.count >= 3 else {
            return false
        }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func leadingSpaceCount(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func indentLevel(forSpaces spaces: Int) -> Int {
        min(max(spaces / 2, 0), 4)
    }

    private static func bulletContent(_ line: String) -> (indent: Int, content: String)? {
        let spaces = leadingSpaceCount(line)
        let remainder = line.dropFirst(spaces)
        guard let marker = remainder.first, marker == "-" || marker == "*" || marker == "+" else {
            return nil
        }
        let afterMarker = remainder.dropFirst()
        guard afterMarker.first == " " || afterMarker.first == "\t" else {
            return nil
        }
        let content = afterMarker.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else {
            return nil
        }
        return (indentLevel(forSpaces: spaces), content)
    }

    private static func orderedContent(_ line: String) -> (indent: Int, number: Int, content: String)? {
        let spaces = leadingSpaceCount(line)
        let remainder = line.dropFirst(spaces)
        let digits = remainder.prefix(while: { $0.isNumber })
        guard (1...9).contains(digits.count) else {
            return nil
        }
        let afterDigits = remainder.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else {
            return nil
        }
        let afterDelimiter = afterDigits.dropFirst()
        guard afterDelimiter.first == " " || afterDelimiter.first == "\t" else {
            return nil
        }
        let content = afterDelimiter.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else {
            return nil
        }
        return (indentLevel(forSpaces: spaces), Int(digits) ?? 1, content)
    }

    // MARK: 行内解析

    static func parseInline(_ text: String) -> [NoteMarkdownInline] {
        let characters = Array(text)
        var inlines: [NoteMarkdownInline] = []
        var buffer = ""
        var index = 0

        func flushBuffer() {
            guard !buffer.isEmpty else {
                return
            }
            inlines.append(.text(buffer))
            buffer.removeAll(keepingCapacity: true)
        }

        while index < characters.count {
            let character = characters[index]

            if character == "\\", index + 1 < characters.count, escapableCharacters.contains(characters[index + 1]) {
                buffer.append(characters[index + 1])
                index += 2
                continue
            }

            if character == "`" {
                if let closing = findClosingDelimiter(in: characters, delimiter: "`", from: index + 1) {
                    flushBuffer()
                    let rawCode = String(characters[(index + 1)..<closing])
                    inlines.append(.code(normalizedCodeSpan(rawCode)))
                    index = closing + 1
                    continue
                }
                buffer.append(character)
                index += 1
                continue
            }

            if character == "!", index + 1 < characters.count, characters[index + 1] == "[" {
                if let scan = NoteMarkdownAttachmentReference.scanImage(at: index, in: characters) {
                    flushBuffer()
                    let altText = decodeEscapeSequences(scan.altText).trimmingCharacters(in: .whitespaces)
                    if let attachmentID = NoteMarkdownAttachmentReference.attachmentID(from: scan.destination) {
                        inlines.append(.image(NoteMarkdownImageReference(attachmentID: attachmentID, altText: altText)))
                    } else {
                        inlines.append(.blockedImage(
                            text: altText,
                            address: scan.destination.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                    }
                    index = scan.endIndex
                    continue
                }
                buffer.append(character)
                index += 1
                continue
            }

            if character == "[" {
                if let scan = NoteMarkdownAttachmentReference.scanBracketDestination(bracketIndex: index, in: characters) {
                    flushBuffer()
                    let label = decodeEscapeSequences(scan.label)
                    if let url = allowedLinkURL(scan.destination) {
                        inlines.append(.link(text: label, destination: url))
                    } else {
                        // 不支持的 scheme：原样显示，不生成可点击链接。
                        buffer.append("[\(scan.label)](\(scan.destination))")
                    }
                    index = scan.endIndex
                    continue
                }
                buffer.append(character)
                index += 1
                continue
            }

            if character == "*" || character == "_" {
                if let emphasis = matchEmphasis(in: characters, at: index) {
                    flushBuffer()
                    inlines.append(emphasis.inline)
                    index = emphasis.endIndex
                    continue
                }
                buffer.append(character)
                index += 1
                continue
            }

            buffer.append(character)
            index += 1
        }

        flushBuffer()
        return inlines
    }

    private static func normalizedCodeSpan(_ raw: String) -> String {
        var content = raw.replacingOccurrences(of: "\n", with: " ")
        // CommonMark：首尾各一个空格时去掉，方便在代码里包含反引号。
        if content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" ") {
            let stripped = String(content.dropFirst().dropLast())
            if !stripped.trimmingCharacters(in: .whitespaces).isEmpty {
                content = stripped
            }
        }
        return content
    }

    private static func matchEmphasis(
        in characters: [Character],
        at index: Int
    ) -> (inline: NoteMarkdownInline, endIndex: Int)? {
        let marker = characters[index]
        guard marker == "*" || marker == "_" else {
            return nil
        }
        if index > 0 {
            let previous = characters[index - 1]
            if marker == "_", previous.isLetter || previous.isNumber {
                // 下划线不适用于单词内部，避免把 snake_case 变成斜体。
                return nil
            }
        }

        let isDouble = index + 1 < characters.count && characters[index + 1] == marker
        let isTriple = isDouble && index + 2 < characters.count && characters[index + 2] == marker
        let delimiterCount = isTriple ? 3 : (isDouble ? 2 : 1)
        let delimiter = String(repeating: String(marker), count: delimiterCount)
        let contentStart = index + delimiterCount
        // CommonMark 的左翼规则：强调符后面必须紧跟非空白，否则是字面量（如 "2 * 3 * 4"）。
        guard contentStart < characters.count, !characters[contentStart].isWhitespace else {
            return nil
        }
        guard let closing = findClosingDelimiter(
            in: characters,
            delimiter: delimiter,
            from: contentStart,
            requireNonAlphanumericAfter: marker == "_"
        ) else {
            return nil
        }
        let content = decodeEscapeSequences(String(characters[contentStart..<closing]))
        guard !content.isEmpty,
              content.first?.isWhitespace == false,
              content.last?.isWhitespace == false else {
            return nil
        }
        let inline: NoteMarkdownInline
        switch delimiterCount {
        case 3:
            inline = .strongEmphasis(content)
        case 2:
            inline = .strong(content)
        default:
            inline = .emphasis(content)
        }
        return (inline, closing + delimiterCount)
    }

    private static func findClosingDelimiter(
        in characters: [Character],
        delimiter: String,
        from start: Int,
        requireNonAlphanumericAfter: Bool = false
    ) -> Int? {
        let delimiterCharacters = Array(delimiter)
        let delimiterLength = delimiterCharacters.count
        guard delimiterLength > 0, start < characters.count else {
            return nil
        }
        var cursor = start
        while cursor + delimiterLength <= characters.count {
            if Array(characters[cursor..<(cursor + delimiterLength)]) == delimiterCharacters {
                let characterBefore = cursor > 0 ? characters[cursor - 1] : nil
                let characterAfter = cursor + delimiterLength < characters.count
                    ? characters[cursor + delimiterLength]
                    : nil
                if characterBefore?.isWhitespace == true {
                    cursor += 1
                    continue
                }
                if requireNonAlphanumericAfter, let characterAfter,
                   characterAfter.isLetter || characterAfter.isNumber {
                    cursor += 1
                    continue
                }
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    static func allowedLinkURL(_ destination: String) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(" "),
              !trimmed.contains("\n"),
              !trimmed.contains("\r"),
              !trimmed.contains("\t") else {
            return nil
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              allowedLinkSchemes.contains(scheme),
              url.host?.isEmpty == false || scheme == "mailto" else {
            return nil
        }
        return url
    }

    static func decodeEscapeSequences(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "\\",
               index + 1 < characters.count,
               escapableCharacters.contains(characters[index + 1]) {
                result.append(characters[index + 1])
                index += 2
            } else {
                result.append(characters[index])
                index += 1
            }
        }
        return result
    }
}

// MARK: - 图片上限与校验

/// 笔记图片的硬性上限。界面在插入前用它做提示，存储层用它兜底。
public enum NoteMarkdownImageLimits {
    /// 单条笔记最多引用的图片数量。
    public static let maximumImagesPerNote = 20
    /// 单张图片的最大字节数（8 MiB）。
    public static let maximumBytesPerImage = 8 * 1024 * 1024
    /// 单张图片的最大像素数（约 1200 万，对应 4000 × 3000）。
    public static let maximumPixelCount = 12_000_000
    /// 替代文本最大长度。
    public static let maximumAltTextLength = 200
    /// 允许的图片 MIME 类型。
    public static let supportedMediaTypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/gif",
        "image/heic",
        "image/heif",
        "image/webp"
    ]

    /// 纯尺寸校验，方便测试和提前提示。
    public static func validate(pixelWidth: Int, pixelHeight: Int) throws {
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw NoteMarkdownImageError.unreadableImage
        }
        let (pixelCount, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !overflow, pixelCount <= maximumPixelCount else {
            throw NoteMarkdownImageError.tooManyPixels(
                pixelCount: overflow ? Int.max : pixelCount,
                limit: maximumPixelCount
            )
        }
    }
}

/// 图片校验失败原因，均带可读文案，界面直接展示，不会崩溃。
public enum NoteMarkdownImageError: Error, LocalizedError, Sendable, Equatable {
    case emptyImage
    case imageTooLarge(byteCount: Int, limit: Int)
    case imageLimitReached(limit: Int)
    case unsupportedFormat
    case tooManyPixels(pixelCount: Int, limit: Int)
    case unreadableImage

    public var errorDescription: String? {
        switch self {
        case .emptyImage:
            return "图片内容为空"
        case .imageTooLarge(let byteCount, let limit):
            return "图片体积 \(NoteMarkdownImageInspector.formattedByteCount(byteCount)) 超过单张上限 \(NoteMarkdownImageInspector.formattedByteCount(limit))"
        case .imageLimitReached(let limit):
            return "单条笔记最多插入 \(limit) 张图片"
        case .unsupportedFormat:
            return "不支持的图片格式，请使用 PNG、JPEG、GIF、HEIC 或 WebP"
        case .tooManyPixels(let pixelCount, let limit):
            return "图片尺寸 \(pixelCount) 像素超过上限 \(limit) 像素"
        case .unreadableImage:
            return "无法读取图片内容"
        }
    }
}

/// 图片元信息。
public struct NoteMarkdownImageProperties: Sendable, Equatable {
    public let mediaType: String
    public let byteCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(mediaType: String, byteCount: Int, pixelWidth: Int, pixelHeight: Int) {
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var pixelCount: Int {
        pixelWidth * pixelHeight
    }
}

/// 只用 ImageIO 读文件头，不把整张图解码进内存，避免大图把 App 打爆。
public enum NoteMarkdownImageInspector {
    /// 校验并返回图片元信息；超限或格式不支持时抛出可读错误。
    public static func inspect(_ data: Data) throws -> NoteMarkdownImageProperties {
        guard !data.isEmpty else {
            throw NoteMarkdownImageError.emptyImage
        }
        guard data.count <= NoteMarkdownImageLimits.maximumBytesPerImage else {
            throw NoteMarkdownImageError.imageTooLarge(
                byteCount: data.count,
                limit: NoteMarkdownImageLimits.maximumBytesPerImage
            )
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw NoteMarkdownImageError.unreadableImage
        }
        // 先判格式：完全不是图片的数据应报 unsupportedFormat，而“像图片但读不出尺寸”才算 unreadableImage。
        guard let typeIdentifier = CGImageSourceGetType(source),
              let unifiedType = UTType(typeIdentifier as String),
              let mediaType = unifiedType.preferredMIMEType,
              NoteMarkdownImageLimits.supportedMediaTypes.contains(mediaType) else {
            throw NoteMarkdownImageError.unsupportedFormat
        }
        guard let rawProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) else {
            throw NoteMarkdownImageError.unreadableImage
        }
        let properties = rawProperties as NSDictionary
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw NoteMarkdownImageError.unreadableImage
        }
        try NoteMarkdownImageLimits.validate(pixelWidth: width, pixelHeight: height)
        return NoteMarkdownImageProperties(
            mediaType: mediaType,
            byteCount: data.count,
            pixelWidth: width,
            pixelHeight: height
        )
    }

    /// 根据文件名或 UTType 猜测 MIME 类型，猜不出时用 `application/octet-stream`。
    public static func mediaType(forFileExtension fileExtension: String) -> String {
        guard !fileExtension.isEmpty,
              let type = UTType(filenameExtension: fileExtension.lowercased()),
              let mediaType = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mediaType
    }

    /// 媒体类型对应的规范扩展名，用于给插入的图片生成安全文件名。
    public static func supportedFileExtensions(for mediaType: String) -> [String] {
        switch mediaType.lowercased() {
        case "image/png": return ["png"]
        case "image/jpeg": return ["jpg", "jpeg"]
        case "image/gif": return ["gif"]
        case "image/heic": return ["heic"]
        case "image/heif": return ["heif"]
        case "image/webp": return ["webp"]
        default: return []
        }
    }

    public static func formattedByteCount(_ byteCount: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(byteCount))
    }
}
