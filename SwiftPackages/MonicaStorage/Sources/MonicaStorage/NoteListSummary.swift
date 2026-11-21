import Foundation

/// 笔记列表（列表 / 瓷砖）需要的纯文本摘要与图片附件统计。
///
/// 这个类型只做纯字符串处理，不访问存储、不读取附件文件，因此可以在列表滚动时反复调用。
/// 它与 Markdown 预览共用 `NoteMarkdownParser.parseInline`，保证「摘要里看到的文字」和
/// 「预览里渲染的文字」一致：标题、引用、列表符号会被去掉，链接只保留文字，行内代码保留代码文字，
/// 围栏代码块与分隔线整体跳过。
///
/// 图片数量只统计真正会被渲染成图片的 `![alt](monica-attachment://id)` 引用：
/// - 围栏代码块里的示例文本不算（块内不做行内解析）；
/// - 行内代码 `![x](…)` 不算（它会被解析成 `.code`）；
/// - 普通链接 `[x](…)` 不算（它会被解析成 `.link`）；
/// - 非法或非 `monica-attachment://` 的地址不算（它会被解析成 `.blockedImage`）；
/// - 同一个附件 id 出现多次只计一张，与 `NoteMarkdownAttachmentReference.attachmentIDs(in:)` 的去重行为一致。
public enum NoteListSummary {
    /// 瓷砖卡片摘要的默认长度（按 Character 计，不是字节）。
    public static let defaultCharacterLimit = 180

    public struct Summary: Sendable, Equatable {
        /// 已经去掉 Markdown 标记、折叠空白并截断的纯文本摘要。
        public let plainText: String
        /// 在正文中被引用到的图片附件 id，按首次出现顺序去重。
        public let imageAttachmentIDs: [String]

        public var imageAttachmentCount: Int {
            imageAttachmentIDs.count
        }

        public var hasImageAttachments: Bool {
            !imageAttachmentIDs.isEmpty
        }

        public init(plainText: String, imageAttachmentIDs: [String]) {
            self.plainText = plainText
            self.imageAttachmentIDs = imageAttachmentIDs
        }
    }

    /// 一次扫描同时得到摘要与图片 id，列表卡片用它避免扫描两遍正文。
    public static func summarize(_ body: String, limit: Int = defaultCharacterLimit) -> Summary {
        let normalized = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty else {
            return Summary(plainText: "", imageAttachmentIDs: [])
        }
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let characterLimit = max(limit, 0)

        var text = ""
        var isTruncated = false
        var imageIDs: [String] = []
        var seenImageIDs: Set<String> = []
        var fence: FenceMarker?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let openFence = fence {
                if isClosingFence(trimmed, marker: openFence) {
                    fence = nil
                }
                continue
            }
            if let marker = fenceMarker(trimmed) {
                fence = marker
                continue
            }
            if trimmed.isEmpty {
                continue
            }
            guard let content = contentText(from: trimmed) else {
                // 分隔线没有可摘要的文字。
                continue
            }

            let inlines = NoteMarkdownParser.parseInline(content)
            var lineBuffer = ""
            for inline in inlines {
                switch inline {
                case .text(let value),
                     .strong(let value),
                     .emphasis(let value),
                     .strongEmphasis(let value),
                     .code(let value):
                    lineBuffer += value
                case .link(let label, _):
                    lineBuffer += label
                case .image(let reference):
                    if seenImageIDs.insert(reference.attachmentID).inserted {
                        imageIDs.append(reference.attachmentID)
                    }
                    // 图片的替代文字是正文的一部分，放进摘要比留下空档更有信息量。
                    lineBuffer += reference.altText
                case .blockedImage(let value, _):
                    lineBuffer += value
                }
            }

            let collapsed = collapsedWhitespace(lineBuffer)
            guard !collapsed.isEmpty, !isTruncated, characterLimit > 0 else {
                continue
            }
            let next = text.isEmpty ? collapsed : text + " " + collapsed
            if next.count > characterLimit {
                text = String(next.prefix(characterLimit))
                isTruncated = true
            } else {
                text = next
            }
        }

        if isTruncated {
            text += "…"
        }
        return Summary(plainText: text, imageAttachmentIDs: imageIDs)
    }

    public static func plainText(from body: String, limit: Int = defaultCharacterLimit) -> String {
        summarize(body, limit: limit).plainText
    }

    public static func imageAttachmentIDs(in body: String) -> [String] {
        summarize(body, limit: 0).imageAttachmentIDs
    }

    public static func imageAttachmentCount(in body: String) -> Int {
        imageAttachmentIDs(in: body).count
    }

    // MARK: - 行级扫描工具
    //
    // 这里刻意只实现「摘要需要的最小集合」，与 `NoteMarkdownParser.parseBlocks` 保持同一套规则：
    // 支持 ATX 标题、引用、无序 / 有序列表、分隔线与围栏代码块；setext 标题等未实现的语法
    // 在两个解析器里同样按普通段落处理，因此不会出现摘要与预览各说各话的情况。

    private struct FenceMarker {
        let character: Character
        let count: Int
    }

    private static func fenceMarker(_ trimmed: String) -> FenceMarker? {
        guard let first = trimmed.first, first == "`" || first == "~" else {
            return nil
        }
        let count = trimmed.prefix(while: { $0 == first }).count
        guard count >= 3 else {
            return nil
        }
        return FenceMarker(character: first, count: count)
    }

    private static func isClosingFence(_ trimmed: String, marker: FenceMarker) -> Bool {
        guard !trimmed.isEmpty else {
            return false
        }
        let markerCount = trimmed.prefix(while: { $0 == marker.character }).count
        guard markerCount >= marker.count else {
            return false
        }
        return trimmed.dropFirst(markerCount).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 去掉块级前缀；返回 nil 表示这一行没有可摘要的文字（分隔线、空标题等）。
    private static func contentText(from trimmed: String) -> String? {
        guard !trimmed.isEmpty else {
            return nil
        }

        if let first = trimmed.first, first == "-" || first == "*" || first == "_" {
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == first }) {
                return nil
            }
        }

        if trimmed.first == "#" {
            let level = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(level) {
                let remainder = trimmed.dropFirst(level)
                if remainder.isEmpty {
                    return nil
                }
                if remainder.first == " " || remainder.first == "\t" {
                    return nonEmpty(remainder.trimmingCharacters(in: .whitespaces))
                }
                return trimmed
            }
        }

        if trimmed.hasPrefix(">") {
            var quoted = String(trimmed.dropFirst())
            if quoted.hasPrefix(" ") {
                quoted.removeFirst()
            }
            return nonEmpty(quoted.trimmingCharacters(in: .whitespaces))
        }

        if let bullet = listContent(from: trimmed) {
            return bullet
        }

        return trimmed
    }

    private static func listContent(from trimmed: String) -> String? {
        guard let marker = trimmed.first else {
            return nil
        }
        if marker == "-" || marker == "*" || marker == "+" {
            let remainder = trimmed.dropFirst()
            if remainder.first == " " || remainder.first == "\t" {
                return nonEmpty(remainder.trimmingCharacters(in: .whitespaces))
            }
            return nil
        }

        let digits = trimmed.prefix(while: { $0.isNumber })
        guard (1...9).contains(digits.count) else {
            return nil
        }
        let afterDigits = trimmed.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else {
            return nil
        }
        let afterDelimiter = afterDigits.dropFirst()
        guard afterDelimiter.first == " " || afterDelimiter.first == "\t" else {
            return nil
        }
        return nonEmpty(afterDelimiter.trimmingCharacters(in: .whitespaces))
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        guard !value.isEmpty else {
            return ""
        }
        return value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
