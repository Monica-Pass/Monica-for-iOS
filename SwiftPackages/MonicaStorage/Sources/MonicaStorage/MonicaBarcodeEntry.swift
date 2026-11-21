import Foundation

/// 条码条目支持的码制。
///
/// 这里只描述「一段原文 + 一种码制」的存储模型，不做登机牌（IATA BCBP）等
/// 任何行业格式的解析。登机牌在本 App 中只是新建条码时的一个预设标题。
public enum BarcodeSymbology: String, Sendable, Equatable, Hashable, CaseIterable, Codable, Identifiable {
    case qr
    case code128
    case ean13
    case pdf417
    case aztec

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qr:
            return "二维码 QR"
        case .code128:
            return "Code 128"
        case .ean13:
            return "EAN-13"
        case .pdf417:
            return "PDF417"
        case .aztec:
            return "Aztec"
        }
    }

    /// 是否为二维码类（二维）码制，用于 UI 排版提示。
    public var isTwoDimensional: Bool {
        switch self {
        case .qr, .pdf417, .aztec:
            return true
        case .code128, .ean13:
            return false
        }
    }
}

public enum BarcodePayloadValidationError: Error, Sendable, Equatable, LocalizedError {
    case emptyPayload
    case payloadTooLong(symbology: BarcodeSymbology, maximumBytes: Int)
    case unsupportedCharacters(symbology: BarcodeSymbology)
    case eanDigitsRequired
    case eanCheckDigitMismatch

    public var errorDescription: String? {
        switch self {
        case .emptyPayload:
            return "条码内容不能为空。"
        case .payloadTooLong(let symbology, let maximumBytes):
            return "\(symbology.displayName) 最多支持 \(maximumBytes) 字节，请缩短内容或改用其他码制。"
        case .unsupportedCharacters(let symbology):
            return "\(symbology.displayName) 只能包含可见 ASCII 字符（字母、数字、常用符号和空格）。"
        case .eanDigitsRequired:
            return "EAN-13 需要 12 位或 13 位数字。"
        case .eanCheckDigitMismatch:
            return "EAN-13 的第 13 位校验位不正确。"
        }
    }
}

/// 条码原文的校验规则。渲染器与保存流程都依赖同一套规则，避免出现
/// 「能保存但生成不出图」或「生成的图与保存内容不一致」的情况。
public enum BarcodePayloadValidator {
    public static let qrMaximumBytes = 2000
    public static let code128MaximumBytes = 80
    public static let pdf417MaximumBytes = 1850
    public static let aztecMaximumBytes = 1900

    public static func maximumBytes(for symbology: BarcodeSymbology) -> Int {
        switch symbology {
        case .qr:
            return qrMaximumBytes
        case .code128:
            return code128MaximumBytes
        case .ean13:
            return 13
        case .pdf417:
            return pdf417MaximumBytes
        case .aztec:
            return aztecMaximumBytes
        }
    }

    public static func validate(_ payload: String, symbology: BarcodeSymbology) throws {
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BarcodePayloadValidationError.emptyPayload
        }

        switch symbology {
        case .ean13:
            try validateEAN13(payload)
        case .code128:
            guard payload.utf8.count <= code128MaximumBytes else {
                throw BarcodePayloadValidationError.payloadTooLong(
                    symbology: symbology,
                    maximumBytes: code128MaximumBytes
                )
            }
            guard payload.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 && $0.value <= 126 }) else {
                throw BarcodePayloadValidationError.unsupportedCharacters(symbology: symbology)
            }
        case .qr, .pdf417, .aztec:
            let limit = maximumBytes(for: symbology)
            guard payload.utf8.count <= limit else {
                throw BarcodePayloadValidationError.payloadTooLong(
                    symbology: symbology,
                    maximumBytes: limit
                )
            }
        }
    }

    /// 校验并返回实际应当保存的内容。EAN-13 会被规范化为 13 位（含校验位），
    /// 其他码制原样返回，保证「原始 payload」不被改写。
    public static func normalizedPayload(_ payload: String, symbology: BarcodeSymbology) throws -> String {
        if symbology == .ean13 {
            return try EAN13Code.normalizedDigits(payload)
        }
        try validate(payload, symbology: symbology)
        return payload
    }

    private static func validateEAN13(_ payload: String) throws {
        _ = try EAN13Code.normalizedDigits(payload)
    }
}

/// EAN-13 的纯数据编码（模块序列），供 UIKit / Core Graphics 渲染使用。
/// 使用系统 Core Image 之外的固定 95 模块编码，不引入第三方依赖。
public enum EAN13Code {
    /// 13 位（首位 + 6 位左码 + 6 位右码）的模块序列，`true` 表示黑条。
    public static func modules(for digits: String) throws -> [Bool] {
        let normalized = try normalizedDigits(digits)
        let values = normalized.compactMap { $0.wholeNumberValue }
        guard values.count == 13 else {
            throw BarcodePayloadValidationError.eanDigitsRequired
        }

        let parity = Array(parityPatterns[values[0]])
        var modules: [Bool] = []
        modules.reserveCapacity(95)

        appendModules("101", to: &modules) // 起始符
        for index in 0..<6 {
            let digit = values[index + 1]
            let table = parity[index] == "G" ? gPatterns[digit] : lPatterns[digit]
            appendModules(table, to: &modules)
        }
        appendModules("01010", to: &modules) // 中间分隔符
        for index in 0..<6 {
            appendModules(rPatterns[values[index + 7]], to: &modules)
        }
        appendModules("101", to: &modules) // 终止符

        return modules
    }

    /// 接受 12 位（自动补校验位）或 13 位（校验位必须正确），返回 13 位数字。
    public static func normalizedDigits(_ digits: String) throws -> String {
        let trimmed = digits.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 12 || trimmed.count == 13,
              trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw BarcodePayloadValidationError.eanDigitsRequired
        }

        let body = String(trimmed.prefix(12))
        let expectedCheckDigit = try checkDigit(forBody: body)

        if trimmed.count == 13 {
            guard trimmed.last == expectedCheckDigit else {
                throw BarcodePayloadValidationError.eanCheckDigitMismatch
            }
            return trimmed
        }
        return body + String(expectedCheckDigit)
    }

    public static func checkDigit(forBody body: String) throws -> Character {
        let values = body.compactMap(\.wholeNumberValue)
        guard body.count == 12, values.count == 12 else {
            throw BarcodePayloadValidationError.eanDigitsRequired
        }
        // 从左到右的位置 1/3/5... 权重为 1，2/4/6... 权重为 3。
        let sum = values.enumerated().reduce(0) { partial, item in
            partial + item.element * (item.offset.isMultiple(of: 2) ? 1 : 3)
        }
        let check = (10 - (sum % 10)) % 10
        return Character(String(check))
    }

    private static func appendModules(_ pattern: String, to modules: inout [Bool]) {
        for character in pattern {
            modules.append(character == "1")
        }
    }

    private static let parityPatterns: [String] = [
        "LLLLLL",
        "LLGLGG",
        "LLGGLG",
        "LLGGGL",
        "LGLLGG",
        "LGGLLG",
        "LGGGLL",
        "LGLGLG",
        "LGLGGL",
        "LGGLGL"
    ]

    private static let lPatterns: [String] = [
        "0001101", "0011001", "0010011", "0111101", "0100011",
        "0110001", "0101111", "0111011", "0110111", "0001011"
    ]

    private static let gPatterns: [String] = [
        "0100111", "0110011", "0011011", "0100001", "0011101",
        "0111001", "0000101", "0010001", "0001001", "0010111"
    ]

    private static let rPatterns: [String] = [
        "1110010", "1100110", "1101100", "1000010", "1011100",
        "1001110", "1010000", "1000100", "1001000", "1110100"
    ]
}

public struct LocalBarcodeEntryDraft: Sendable, Equatable {
    public let title: String
    public let symbology: BarcodeSymbology
    public let payload: String
    public let label: String
    public let notes: String
    public let metadata: VaultEntryMetadata

    public init(
        title: String,
        symbology: BarcodeSymbology,
        payload: String,
        label: String = "",
        notes: String = "",
        metadata: VaultEntryMetadata = .empty
    ) {
        self.title = title
        self.symbology = symbology
        self.payload = payload
        self.label = label
        self.notes = notes
        self.metadata = metadata
    }

    /// 返回规范化后的草稿；EAN-13 会补全/校验校验位。
    public func validated() throws -> LocalBarcodeEntryDraft {
        let normalizedPayload = try BarcodePayloadValidator.normalizedPayload(payload, symbology: symbology)
        return LocalBarcodeEntryDraft(
            title: title,
            symbology: symbology,
            payload: normalizedPayload,
            label: label,
            notes: notes
        )
    }
}

public struct LocalBarcodeEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let symbology: BarcodeSymbology
    public let payload: String
    public let label: String
    public let notes: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        symbology: BarcodeSymbology,
        payload: String,
        label: String = "",
        notes: String = "",
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.symbology = symbology
        self.payload = payload
        self.label = label
        self.notes = notes
        self.favorite = favorite
    }

    public init(id: String, projectID: String, draft: LocalBarcodeEntryDraft, favorite: Bool = false) {
        self.init(
            id: id,
            projectID: projectID,
            title: draft.title,
            symbology: draft.symbology,
            payload: draft.payload,
            label: draft.label,
            notes: draft.notes,
            favorite: favorite
        )
    }

    public var draft: LocalBarcodeEntryDraft {
        LocalBarcodeEntryDraft(
            title: title,
            symbology: symbology,
            payload: payload,
            label: label,
            notes: notes
        )
    }

    /// 列表/详情使用的副标题：优先显示用户填写的标签，否则显示码制。
    public var displaySubtitle: String {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedLabel.isEmpty ? symbology.displayName : trimmedLabel
    }
}

/// 条码条目在 MDBX payload 中的编码。保留 `schemaVersion` 以便后续迁移，
/// 缺少字段时回退到安全默认值（Android 备份导入没有制式字段时按 QR 处理）。
public enum BarcodeEntryPayloadCodec {
    public static let schemaVersion = 1

    public enum Key {
        public static let schemaVersion = "schemaVersion"
        public static let symbology = "symbology"
        public static let payload = "payload"
        public static let label = "label"
        public static let notes = "notes"
    }

    public static func encoded(_ draft: LocalBarcodeEntryDraft) -> [String: Any] {
        [
            Key.schemaVersion: schemaVersion,
            Key.symbology: draft.symbology.rawValue,
            Key.payload: draft.payload,
            Key.label: draft.label,
            Key.notes: draft.notes
        ]
    }

    public static func decoded(
        _ payload: [String: Any],
        entryID: String,
        projectID: String,
        title: String,
        favorite: Bool
    ) -> LocalBarcodeEntry {
        let symbology = (payload[Key.symbology] as? String)
            .flatMap(BarcodeSymbology.init(rawValue:)) ?? .qr
        return LocalBarcodeEntry(
            id: entryID,
            projectID: projectID,
            title: title,
            symbology: symbology,
            payload: payload[Key.payload] as? String ?? "",
            label: payload[Key.label] as? String ?? "",
            notes: payload[Key.notes] as? String ?? "",
            favorite: favorite
        )
    }
}
