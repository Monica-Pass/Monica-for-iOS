import CryptoKit
import Foundation

// MARK: - 导出格式

/// 用户可选的整库导出格式。
public enum VaultExportFormat: String, Sendable, CaseIterable, Equatable {
    case csv
    case json

    /// 格式名本身是品牌/技术名词，中英文一致。
    public var displayName: String {
        switch self {
        case .csv:
            return "CSV"
        case .json:
            return "JSON"
        }
    }

    public var fileExtension: String {
        rawValue
    }
}

// MARK: - 导入来源格式

/// 导入文件的内容格式。扩展名只作为旁证，最终以内容签名为准。
public enum VaultImportSourceFormat: String, Sendable, CaseIterable, Equatable {
    case monicaCSV = "monica-csv"
    case monicaJSON = "monica-json"
    case bitwardenJSON = "bitwarden-json"
    case aegisJSON = "aegis-json"
    case stratumJSON = "stratum-json"
    case onePasswordCSV = "1password-csv"
    case genericCSV = "generic-csv"

    public var displayName: String {
        switch self {
        case .monicaCSV:
            return "Monica CSV"
        case .monicaJSON:
            return "Monica JSON"
        case .bitwardenJSON:
            return "Bitwarden JSON"
        case .aegisJSON:
            return "Aegis JSON"
        case .stratumJSON:
            return "Stratum JSON"
        case .onePasswordCSV:
            return "1Password CSV"
        case .genericCSV:
            return String(localized: "通用 CSV")
        }
    }

    public var isCSV: Bool {
        switch self {
        case .monicaCSV, .onePasswordCSV, .genericCSV:
            return true
        case .monicaJSON, .bitwardenJSON, .aegisJSON, .stratumJSON:
            return false
        }
    }
}

// MARK: - 格式识别

public enum VaultImportDetectionOutcome: Sendable, Equatable {
    /// 可以继续预览/导入。
    case supported(VaultImportSourceFormat)
    /// 文件本身是加密信封，需要用户输入密码。
    case passwordRequired
    /// 识别出了来源，但它是对方 App 的加密导出，本 App 不解析。
    case unsupportedEncryption(VaultImportSourceFormat)
    /// 完全无法识别，或文件不合格（过大/为空）。
    case unsupported
}

public struct VaultImportEvidence: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case contentType
        case fileExtension
        case contentSignature
    }

    public let source: Source
    public let detail: String

    public init(source: Source, detail: String) {
        self.source = source
        self.detail = detail
    }
}

public struct VaultImportDetection: Sendable, Equatable {
    public let outcome: VaultImportDetectionOutcome
    public let fileName: String?
    public let contentType: String?
    public let evidence: [VaultImportEvidence]
    public let warnings: [String]
    public let message: String

    public init(
        outcome: VaultImportDetectionOutcome,
        fileName: String? = nil,
        contentType: String? = nil,
        evidence: [VaultImportEvidence] = [],
        warnings: [String] = [],
        message: String
    ) {
        self.outcome = outcome
        self.fileName = fileName
        self.contentType = contentType
        self.evidence = evidence
        self.warnings = warnings
        self.message = message
    }

    public var detectedFormat: VaultImportSourceFormat? {
        switch outcome {
        case .supported(let format), .unsupportedEncryption(let format):
            return format
        case .passwordRequired, .unsupported:
            return nil
        }
    }

    public var requiresPassword: Bool {
        outcome == .passwordRequired
    }

    public var isSupported: Bool {
        if case .supported = outcome {
            return true
        }
        return false
    }
}

/// 内容优先的格式嗅探：先看加密信封/二进制头，再看 JSON 顶层键，最后才看 CSV 表头。
/// 扩展名与 MIME 只用于给出证据和“扩展名与内容不一致”的提示，永远不覆盖内容判断。
public enum VaultImportDetector {
    /// 超过这个大小的文件直接拒绝，避免一次性把巨型文件读进内存。
    public static let maximumFileSizeBytes = 32 * 1024 * 1024

    private static let stratumBinaryMagics: [Data] = [
        Data("AUTHENTICATORPRO".utf8),
        Data("AuthenticatorPro".utf8)
    ]

    public static func detect(
        data: Data,
        fileName: String? = nil,
        contentType: String? = nil
    ) -> VaultImportDetection {
        var evidence: [VaultImportEvidence] = []
        var warnings: [String] = []

        if let contentType, !contentType.isEmpty {
            evidence.append(VaultImportEvidence(source: .contentType, detail: contentType))
        }
        let fileExtension = normalizedFileExtension(fileName)
        if !fileExtension.isEmpty {
            evidence.append(VaultImportEvidence(source: .fileExtension, detail: ".\(fileExtension)"))
        }

        func result(
            _ outcome: VaultImportDetectionOutcome,
            _ message: String,
            extraEvidence: [VaultImportEvidence] = []
        ) -> VaultImportDetection {
            VaultImportDetection(
                outcome: outcome,
                fileName: fileName,
                contentType: contentType,
                evidence: evidence + extraEvidence,
                warnings: warnings,
                message: message
            )
        }

        guard data.count <= maximumFileSizeBytes else {
            return result(.unsupported, "文件超过 32 MB，已拒绝导入。")
        }
        guard !data.isEmpty else {
            return result(.unsupported, "文件为空，没有可导入的内容。")
        }

        // 1. 本 App 的加密信封（CSV/JSON 加密导出与移动端备份共用同一信封）。
        if AndroidBackupCodec.isEncryptedPayload(data) {
            return result(
                .passwordRequired,
                "文件已加密，请输入导出时设置的密码。",
                extraEvidence: [VaultImportEvidence(source: .contentSignature, detail: "MONICA_ENC_V1 加密信封")]
            )
        }

        // 2. Stratum 加密备份是二进制头，不能按 JSON 解析。
        if let magic = stratumBinaryMagics.first(where: { data.starts(with: $0) }) {
            let header = String(decoding: magic, as: UTF8.self)
            return result(
                .unsupportedEncryption(.stratumJSON),
                "检测到 Stratum 加密备份（\(header)），该加密格式暂不支持解析。请在 Stratum 中导出未加密备份后再导入。",
                extraEvidence: [VaultImportEvidence(source: .contentSignature, detail: "二进制头 \(header)")]
            )
        }

        // 3. JSON：看顶层键。
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let keys = object.keys.sorted().prefix(6).joined(separator: ",")
            let jsonEvidence = VaultImportEvidence(source: .contentSignature, detail: "JSON 顶层键 [\(keys)]")

            if let format = object["format"] as? String, format == "monica-vault" {
                return finish(
                    .supported(.monicaJSON),
                    base: result(.supported(.monicaJSON), "识别为 Monica JSON 导出。", extraEvidence: [jsonEvidence]),
                    fileExtension: fileExtension,
                    expectedExtension: "json",
                    warnings: &warnings
                )
            }
            if object["Authenticators"] is [Any] {
                return finish(
                    .supported(.stratumJSON),
                    base: result(.supported(.stratumJSON), "识别为 Stratum 明文备份。", extraEvidence: [jsonEvidence]),
                    fileExtension: fileExtension,
                    expectedExtension: "json",
                    warnings: &warnings
                )
            }
            if object["header"] is [String: Any], object["version"] != nil {
                if object["db"] is String {
                    return result(
                        .unsupportedEncryption(.aegisJSON),
                        "检测到 Aegis 加密备份，其密钥由原生加密槽派生，本 App 暂不支持解密。请在 Aegis 中导出明文备份后再导入。",
                        extraEvidence: [jsonEvidence]
                    )
                }
                if object["db"] is [String: Any] {
                    return finish(
                        .supported(.aegisJSON),
                        base: result(.supported(.aegisJSON), "识别为 Aegis 明文备份。", extraEvidence: [jsonEvidence]),
                        fileExtension: fileExtension,
                        expectedExtension: "json",
                        warnings: &warnings
                    )
                }
            }
            if jsonBool(object["encrypted"]) == true {
                return result(
                    .unsupportedEncryption(.bitwardenJSON),
                    "检测到 Bitwarden 加密导出（encrypted: true）。请先在 Bitwarden 中导出未加密 JSON 再导入。",
                    extraEvidence: [jsonEvidence]
                )
            }
            if object["items"] is [Any] {
                return finish(
                    .supported(.bitwardenJSON),
                    base: result(.supported(.bitwardenJSON), "识别为 Bitwarden 未加密 JSON 导出。", extraEvidence: [jsonEvidence]),
                    fileExtension: fileExtension,
                    expectedExtension: "json",
                    warnings: &warnings
                )
            }
            return result(.unsupported, "无法识别的 JSON 文件：缺少已知的顶层字段。", extraEvidence: [jsonEvidence])
        }

        // 4. 文本：按 CSV 表头识别。
        guard let text = decodedText(from: data) else {
            return result(.unsupported, "文件既不是可解析的 JSON，也不是 UTF-8 文本。")
        }
        guard let rows = try? VaultCSVCodec.parseRows(text), let headerRow = rows.first, !headerRow.isEmpty else {
            return result(.unsupported, "CSV 缺少表头，无法识别列。")
        }
        let header = headerRow.map(normalizedColumnName)
        let headerEvidence = VaultImportEvidence(
            source: .contentSignature,
            detail: "CSV 表头 [\(header.prefix(6).joined(separator: ","))]"
        )

        if header.contains("kind") {
            return finish(
                .supported(.monicaCSV),
                base: result(.supported(.monicaCSV), "识别为 Monica CSV 导出。", extraEvidence: [headerEvidence]),
                fileExtension: fileExtension,
                expectedExtension: "csv",
                warnings: &warnings
            )
        }
        if header.contains("otpauth") || header.contains("title") && header.contains("url") && header.contains("username") && header.contains("password") {
            if header.contains("otpauth") || header.contains("tags") {
                return finish(
                    .supported(.onePasswordCSV),
                    base: result(.supported(.onePasswordCSV), "识别为 1Password CSV 导出。", extraEvidence: [headerEvidence]),
                    fileExtension: fileExtension,
                    expectedExtension: "csv",
                    warnings: &warnings
                )
            }
            return finish(
                .supported(.genericCSV),
                base: result(.supported(.genericCSV), "识别为通用账号 CSV。", extraEvidence: [headerEvidence]),
                fileExtension: fileExtension,
                expectedExtension: "csv",
                warnings: &warnings
            )
        }
        if header.contains(where: { VaultCSVColumnMapping.titleAliases.contains($0) })
            && header.contains(where: { VaultCSVColumnMapping.passwordAliases.contains($0) || VaultCSVColumnMapping.otpAliases.contains($0) }) {
            return finish(
                .supported(.genericCSV),
                base: result(.supported(.genericCSV), "识别为通用账号 CSV。", extraEvidence: [headerEvidence]),
                fileExtension: fileExtension,
                expectedExtension: "csv",
                warnings: &warnings
            )
        }
        return result(.unsupported, "无法识别的 CSV：表头里没有标题/密码等已知列。", extraEvidence: [headerEvidence])
    }

    private static func finish(
        _ outcome: VaultImportDetectionOutcome,
        base: VaultImportDetection,
        fileExtension: String,
        expectedExtension: String,
        warnings: inout [String]
    ) -> VaultImportDetection {
        var extraWarnings = base.warnings
        if !fileExtension.isEmpty, fileExtension != expectedExtension {
            extraWarnings.append("扩展名 .\(fileExtension) 与内容不一致，已按内容识别。")
        }
        return VaultImportDetection(
            outcome: base.outcome,
            fileName: base.fileName,
            contentType: base.contentType,
            evidence: base.evidence,
            warnings: extraWarnings,
            message: base.message
        )
    }

    static func normalizedFileExtension(_ fileName: String?) -> String {
        guard let fileName, !fileName.isEmpty else { return "" }
        return (fileName as NSString).pathExtension.lowercased()
    }

    static func decodedText(from data: Data) -> String? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        return text
    }

    static func normalizedColumnName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{FEFF}"))
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }
}

// MARK: - 统一中间模型

/// 一条待导入条目：草稿 + 自定义字段 + 稳定来源信息。
/// `sourceID` 只用于展示/排错，不落库（本地仓库没有对应的外部 ID 列）。
public struct VaultTransferItem: Sendable, Equatable {
    public let draft: VaultCSVItemDraft
    public let customFields: [VaultCustomField]
    public let sourceIndex: Int
    public let sourceID: String?

    public init(
        draft: VaultCSVItemDraft,
        customFields: [VaultCustomField] = [],
        sourceIndex: Int = 0,
        sourceID: String? = nil
    ) {
        self.draft = draft
        self.customFields = customFields
        self.sourceIndex = sourceIndex
        self.sourceID = sourceID
    }
}

public enum VaultImportIssueCode: String, Sendable, CaseIterable, Equatable {
    /// 文件级：不是本 App 能读的文件。
    case unsupportedFile
    /// 文件级：内容签名识别不出来。
    case unrecognizedFormat
    /// 文件级：来源是加密导出，本 App 不解密。
    case encryptedFormat
    /// 文件级：超过 32 MB 上限。
    case fileTooLarge
    /// 文件级：加密文件没给密码，或密码错。
    case passwordRequired
    case decryptionFailed
    case malformedJSON
    case malformedCSV
    case missingKindColumn
    case unsupportedVersion
    /// 单条：条目类型当前不支持导入。
    case unsupportedItemKind
    case missingRequiredField
    case invalidField
    case duplicateItem
    /// 单条：部分字段没有对应位置，已跳过但不影响其它字段。
    case skippedValue
}

public struct VaultImportIssue: Sendable, Equatable {
    /// 0 起的条目下标；文件级问题为 nil。
    public let sourceIndex: Int?
    public let field: String?
    public let code: VaultImportIssueCode
    public let message: String

    public init(
        sourceIndex: Int? = nil,
        code: VaultImportIssueCode,
        field: String? = nil,
        message: String
    ) {
        self.sourceIndex = sourceIndex
        self.field = field
        self.code = code
        self.message = message
    }
}

public struct VaultImportResult: Sendable, Equatable {
    public let detection: VaultImportDetection
    public let items: [VaultTransferItem]
    public let issues: [VaultImportIssue]
    public let sourceItemCount: Int
    public let skippedDuplicateCount: Int

    public init(
        detection: VaultImportDetection,
        items: [VaultTransferItem],
        issues: [VaultImportIssue],
        sourceItemCount: Int,
        skippedDuplicateCount: Int
    ) {
        self.detection = detection
        self.items = items
        self.issues = issues
        self.sourceItemCount = sourceItemCount
        self.skippedDuplicateCount = skippedDuplicateCount
    }

    public var format: VaultImportSourceFormat? {
        detection.detectedFormat
    }

    public var canImport: Bool {
        detection.isSupported && !items.isEmpty
    }

    public var skippedItemCount: Int {
        max(0, sourceItemCount - items.count)
    }
}

public struct VaultImportOptions: Sendable, Equatable {
    /// 加密文件的密码；只用于内存解密，不会被记录。
    public var password: String?
    /// 判重用的本地既有条目。
    public var existingLoginEntries: [LocalLoginEntry]
    public var existingTotpEntries: [LocalTotpEntry]
    /// 关掉后仍然解析，只是不跳过重复。
    public var deduplicate: Bool

    public init(
        password: String? = nil,
        existingLoginEntries: [LocalLoginEntry] = [],
        existingTotpEntries: [LocalTotpEntry] = [],
        deduplicate: Bool = true
    ) {
        self.password = password
        self.existingLoginEntries = existingLoginEntries
        self.existingTotpEntries = existingTotpEntries
        self.deduplicate = deduplicate
    }
}

// MARK: - 导入引擎

public enum VaultImportEngine {
    /// 全量解析，不触碰本地 Vault。只有 `items` 非空且用户确认后，App 才会逐条写入。
    public static func preview(
        data: Data,
        fileName: String? = nil,
        contentType: String? = nil,
        options: VaultImportOptions = VaultImportOptions()
    ) -> VaultImportResult {
        var detection = VaultImportDetector.detect(data: data, fileName: fileName, contentType: contentType)

        if case .unsupported = detection.outcome {
            var code = VaultImportIssueCode.unsupportedFile
            if data.count > VaultImportDetector.maximumFileSizeBytes {
                code = .fileTooLarge
            } else if !data.isEmpty {
                code = .unrecognizedFormat
            }
            return VaultImportResult(
                detection: detection,
                items: [],
                issues: [VaultImportIssue(code: code, message: detection.message)],
                sourceItemCount: 0,
                skippedDuplicateCount: 0
            )
        }
        if case .unsupportedEncryption = detection.outcome {
            return VaultImportResult(
                detection: detection,
                items: [],
                issues: [VaultImportIssue(code: .encryptedFormat, message: detection.message)],
                sourceItemCount: 0,
                skippedDuplicateCount: 0
            )
        }
        if case .passwordRequired = detection.outcome {
            guard let password = options.password, !password.isEmpty else {
                return VaultImportResult(
                    detection: detection,
                    items: [],
                    issues: [VaultImportIssue(code: .passwordRequired, message: "文件已加密，请输入密码后再导入。")],
                    sourceItemCount: 0,
                    skippedDuplicateCount: 0
                )
            }
            let decrypted: Data
            do {
                decrypted = try AndroidBackupCodec.decryptPayload(data, password: password)
            } catch {
                return VaultImportResult(
                    detection: detection,
                    items: [],
                    issues: [VaultImportIssue(code: .decryptionFailed, message: "解密失败：密码不正确或文件已损坏。")],
                    sourceItemCount: 0,
                    skippedDuplicateCount: 0
                )
            }
            let inner = VaultImportDetector.detect(data: decrypted, fileName: fileName, contentType: contentType)
            guard case .supported = inner.outcome else {
                return VaultImportResult(
                    detection: inner,
                    items: [],
                    issues: [VaultImportIssue(code: .encryptedFormat, message: inner.message)],
                    sourceItemCount: 0,
                    skippedDuplicateCount: 0
                )
            }
            detection = VaultImportDetection(
                outcome: inner.outcome,
                fileName: inner.fileName,
                contentType: inner.contentType,
                evidence: inner.evidence + [VaultImportEvidence(source: .contentSignature, detail: "已用密码解密")],
                warnings: inner.warnings,
                message: inner.message
            )
            return parse(data: decrypted, detection: detection, options: options)
        }
        return parse(data: data, detection: detection, options: options)
    }

    private static func parse(
        data: Data,
        detection: VaultImportDetection,
        options: VaultImportOptions
    ) -> VaultImportResult {
        guard let format = detection.detectedFormat else {
            return VaultImportResult(
                detection: detection,
                items: [],
                issues: [VaultImportIssue(code: .unrecognizedFormat, message: detection.message)],
                sourceItemCount: 0,
                skippedDuplicateCount: 0
            )
        }

        var parsed = VaultImportParseResult()
        switch format {
        case .monicaCSV:
            parsed = VaultCSVTransferImporter.parseMonicaCSV(data: data)
        case .onePasswordCSV:
            parsed = VaultCSVTransferImporter.parseMappedCSV(data: data, sourceFormat: .onePasswordCSV)
        case .genericCSV:
            parsed = VaultCSVTransferImporter.parseMappedCSV(data: data, sourceFormat: .genericCSV)
        case .monicaJSON:
            parsed = VaultMonicaJSONImporter.parse(data: data)
        case .bitwardenJSON:
            parsed = VaultBitwardenJSONImporter.parse(data: data)
        case .aegisJSON:
            parsed = VaultAegisJSONImporter.parse(data: data)
        case .stratumJSON:
            parsed = VaultStratumJSONImporter.parse(data: data)
        }

        let deduplicated = VaultImportDeduplicator.apply(items: parsed.items, options: options)
        return VaultImportResult(
            detection: detection,
            items: deduplicated.items,
            issues: parsed.issues + deduplicated.issues,
            sourceItemCount: parsed.sourceItemCount,
            skippedDuplicateCount: deduplicated.skippedCount
        )
    }
}

struct VaultImportParseResult {
    var items: [VaultTransferItem] = []
    var issues: [VaultImportIssue] = []
    var sourceItemCount: Int = 0
}

// MARK: - 判重

enum VaultImportDeduplicator {
    struct Output {
        let items: [VaultTransferItem]
        let issues: [VaultImportIssue]
        let skippedCount: Int
    }

    static func apply(items: [VaultTransferItem], options: VaultImportOptions) -> Output {
        guard options.deduplicate else {
            return Output(items: items, issues: [], skippedCount: 0)
        }
        var knownKeys = Set<String>()
        for entry in options.existingLoginEntries {
            if let key = loginKey(url: entry.url, username: entry.username, password: entry.password) {
                knownKeys.insert(key)
            }
        }
        for entry in options.existingTotpEntries {
            if let key = totpKey(
                secret: entry.secret,
                accountName: entry.accountName,
                issuer: entry.issuer,
                title: entry.title
            ) {
                knownKeys.insert(key)
            }
        }

        var kept: [VaultTransferItem] = []
        var issues: [VaultImportIssue] = []
        var skippedCount = 0
        kept.reserveCapacity(items.count)
        for item in items {
            guard let key = key(for: item.draft) else {
                kept.append(item)
                continue
            }
            if knownKeys.contains(key) {
                skippedCount += 1
                issues.append(VaultImportIssue(
                    sourceIndex: item.sourceIndex,
                    code: .duplicateItem,
                    field: nil,
                    message: "第 \(item.sourceIndex + 1) 条：与已有条目重复，已跳过。"
                ))
                continue
            }
            knownKeys.insert(key)
            kept.append(item)
        }
        return Output(items: kept, issues: issues, skippedCount: skippedCount)
    }

    /// 只有登录与 TOTP 有可靠的天然主键；其它类型不做判重，避免误伤同标题条目。
    static func key(for draft: VaultCSVItemDraft) -> String? {
        switch draft {
        case .login(let entry):
            return loginKey(url: entry.url, username: entry.username, password: entry.password)
        case .totp(let entry):
            return totpKey(
                secret: entry.secret,
                accountName: entry.accountName,
                issuer: entry.issuer,
                title: entry.title
            )
        default:
            return nil
        }
    }

    static func loginKey(url: String, username: String, password: String) -> String? {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedUsername.isEmpty || !password.isEmpty else { return nil }
        return "login|\(CredentialExchangeCodec.normalizedURLKey(url))|\(normalizedUsername)|\(password)"
    }

    static func totpKey(secret: String, accountName: String, issuer: String = "", title: String = "") -> String? {
        guard let normalizedSecret = CredentialExchangeCodec.Base32.normalizedSecret(secret) else {
            return nil
        }
        let account = accountName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let issuerKey = issuer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if account.isEmpty && issuerKey.isEmpty {
            // 没有发行方/账号时退回标题，避免把同一密钥下的不同条目误判成重复。
            return "totp|\(normalizedSecret)|\(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }
        return "totp|\(normalizedSecret)|\(issuerKey)|\(account)"
    }
}

// MARK: - Bitwarden 未加密 JSON

enum VaultBitwardenJSONImporter {
    static func parse(data: Data) -> VaultImportParseResult {
        var result = VaultImportParseResult()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            result.issues.append(VaultImportIssue(code: .malformedJSON, message: "JSON 解析失败，文件可能已损坏。"))
            return result
        }
        guard let rawItems = object["items"] as? [Any] else {
            result.issues.append(VaultImportIssue(code: .malformedJSON, message: "缺少 items 数组。"))
            return result
        }
        result.sourceItemCount = rawItems.count
        let folders = folderNames(object["folders"])
        var favoriteSkipped = false

        for (index, raw) in rawItems.enumerated() {
            guard let item = raw as? [String: Any] else {
                result.issues.append(issue(index, code: .invalidField, message: "条目不是 JSON 对象，已跳过。"))
                continue
            }
            if jsonString(item["deletedDate"])?.isEmpty == false {
                // 回收站里的条目不导入，避免把已删除的旧密码带回来。
                continue
            }
            let name = jsonString(item["name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else {
                result.issues.append(issue(index, code: .missingRequiredField, field: "name", message: "第 \(index + 1) 条缺少 name，已跳过。"))
                continue
            }
            if jsonBool(item["favorite"]) == true, !favoriteSkipped {
                favoriteSkipped = true
                result.issues.append(VaultImportIssue(
                    sourceIndex: index,
                    code: .skippedValue,
                    field: "favorite",
                    message: "收藏标记暂不随导入保留。"
                ))
            }
            let sourceID = jsonString(item["id"])
            let type = jsonInt(item["type"]) ?? -1
            let notes = jsonString(item["notes"]) ?? ""

            switch type {
            case 1:
                importLogin(item, index: index, name: name, notes: notes, sourceID: sourceID, folders: folders, into: &result)
            case 2:
                result.items.append(VaultTransferItem(
                    draft: .note(LocalNoteEntryDraft(title: name, body: notes)),
                    sourceIndex: index,
                    sourceID: sourceID
                ))
            case 3:
                importCard(item, index: index, name: name, notes: notes, sourceID: sourceID, into: &result)
            case 4:
                importIdentity(item, index: index, name: name, notes: notes, sourceID: sourceID, into: &result)
            default:
                result.issues.append(issue(
                    index,
                    code: .unsupportedItemKind,
                    field: "type",
                    message: "第 \(index + 1) 条的类型 \(type) 暂不支持导入，已跳过。"
                ))
            }
        }
        return result
    }

    private static func importLogin(
        _ item: [String: Any],
        index: Int,
        name: String,
        notes: String,
        sourceID: String?,
        folders: [String: String],
        into result: inout VaultImportParseResult
    ) {
        let login = jsonObject(item["login"]) ?? [:]
        let uris = (login["uris"] as? [Any]) ?? []
        let uriValues = uris.compactMap { entry -> String? in
            if let dict = entry as? [String: Any] {
                return jsonString(dict["uri"])
            }
            return jsonString(entry)
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        let username = jsonString(login["username"]) ?? ""
        let password = jsonString(login["password"]) ?? ""
        let draft = LocalLoginEntryDraft(
            title: name,
            username: username,
            password: password,
            url: uriValues.first ?? "",
            notes: notes,
            urls: uriValues
        )
        var customFields = parseFields(item["fields"])
        if let folderID = jsonString(item["folderId"]), let folderName = folders[folderID] {
            customFields.append(VaultCustomField(
                label: String(localized: "文件夹"),
                kind: .text,
                value: folderName,
                order: customFields.count
            ))
        }
        result.items.append(VaultTransferItem(
            draft: .login(draft),
            customFields: customFields,
            sourceIndex: index,
            sourceID: sourceID
        ))

        guard let totp = jsonString(login["totp"])?.trimmingCharacters(in: .whitespacesAndNewlines), !totp.isEmpty else {
            return
        }
        if let otp = VaultOTPAuthURI.parse(totp) {
            result.items.append(VaultTransferItem(
                draft: .totp(LocalTotpEntryDraft(
                    title: name,
                    secret: otp.secret,
                    issuer: otp.issuer,
                    accountName: otp.accountName.isEmpty ? username : otp.accountName,
                    period: UInt32(otp.period),
                    digits: UInt32(otp.digits),
                    algorithm: otp.algorithm,
                    otpType: otp.otpType,
                    counter: UInt64(otp.counter)
                )),
                customFields: [],
                sourceIndex: index,
                sourceID: sourceID.map { "\($0)#totp" }
            ))
        } else if let secret = CredentialExchangeCodec.Base32.normalizedSecret(totp) {
            result.items.append(VaultTransferItem(
                draft: .totp(LocalTotpEntryDraft(
                    title: name,
                    secret: secret,
                    issuer: "",
                    accountName: username,
                    period: 30,
                    digits: 6,
                    algorithm: "SHA1",
                    otpType: "totp",
                    counter: 0
                )),
                customFields: [],
                sourceIndex: index,
                sourceID: sourceID.map { "\($0)#totp" }
            ))
        } else {
            result.issues.append(issue(
                index,
                code: .invalidField,
                field: "login.totp",
                message: "第 \(index + 1) 条的 TOTP 既不是 otpauth 链接也不是合法 Base32 密钥，已跳过该验证器。"
            ))
        }
    }

    private static func importCard(
        _ item: [String: Any],
        index: Int,
        name: String,
        notes: String,
        sourceID: String?,
        into result: inout VaultImportParseResult
    ) {
        let card = jsonObject(item["card"]) ?? [:]
        let brand = jsonString(card["brand"]) ?? ""
        result.items.append(VaultTransferItem(
            draft: .card(LocalCardEntryDraft(
                title: name,
                cardholderName: jsonString(card["cardholderName"]) ?? "",
                number: jsonString(card["number"]) ?? "",
                expiryMonth: jsonString(card["expMonth"]) ?? "",
                expiryYear: jsonString(card["expYear"]) ?? "",
                cvv: jsonString(card["code"]) ?? "",
                issuer: brand,
                network: brand,
                notes: notes
            )),
            sourceIndex: index,
            sourceID: sourceID
        ))
    }

    private static func importIdentity(
        _ item: [String: Any],
        index: Int,
        name: String,
        notes: String,
        sourceID: String?,
        into result: inout VaultImportParseResult
    ) {
        let identity = jsonObject(item["identity"]) ?? [:]
        let fullName = ["firstName", "middleName", "lastName"]
            .compactMap { jsonString(identity[$0])?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let documentType: String
        let documentNumber: String
        if let passport = jsonString(identity["passportNumber"]), !passport.isEmpty {
            documentType = "passport"
            documentNumber = passport
        } else if let license = jsonString(identity["licenseNumber"]), !license.isEmpty {
            documentType = "license"
            documentNumber = license
        } else if let ssn = jsonString(identity["ssn"]), !ssn.isEmpty {
            documentType = "id"
            documentNumber = ssn
        } else {
            documentType = "id"
            documentNumber = ""
        }

        // 地址、电话、邮箱等没有对应的本地列，拼进备注避免丢字段。
        var extraLines: [String] = []
        for key in ["email", "phone", "address1", "address2", "address3", "city", "state", "postalCode", "country"] {
            guard let value = jsonString(identity[key])?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                continue
            }
            extraLines.append("\(key): \(value)")
        }
        let mergedNotes = ([notes] + extraLines).filter { !$0.isEmpty }.joined(separator: "\n")

        result.items.append(VaultTransferItem(
            draft: .identity(LocalIdentityEntryDraft(
                title: name,
                documentType: documentType,
                fullName: fullName,
                documentNumber: documentNumber,
                issuer: jsonString(identity["company"]) ?? "",
                country: jsonString(identity["country"]) ?? "",
                issueDate: "",
                expiryDate: "",
                notes: mergedNotes
            )),
            sourceIndex: index,
            sourceID: sourceID
        ))
    }

    private static func parseFields(_ value: Any?) -> [VaultCustomField] {
        guard let rawFields = value as? [Any] else { return [] }
        var fields: [VaultCustomField] = []
        for raw in rawFields {
            guard let dict = raw as? [String: Any] else { continue }
            let label = jsonString(dict["name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fieldValue = jsonString(dict["value"]) ?? ""
            guard !label.isEmpty, !fieldValue.isEmpty else { continue }
            let kind: VaultCustomFieldKind = jsonInt(dict["type"]) == 1 ? .hiddenText : .text
            fields.append(VaultCustomField(
                label: label,
                kind: kind,
                value: fieldValue,
                order: fields.count
            ))
        }
        return fields
    }

    private static func folderNames(_ value: Any?) -> [String: String] {
        guard let folders = value as? [Any] else { return [:] }
        var names: [String: String] = [:]
        for raw in folders {
            guard let dict = raw as? [String: Any],
                  let id = jsonString(dict["id"]),
                  let name = jsonString(dict["name"]) else {
                continue
            }
            names[id] = name
        }
        return names
    }
}

// MARK: - Aegis 明文 JSON

enum VaultAegisJSONImporter {
    static func parse(data: Data) -> VaultImportParseResult {
        var result = VaultImportParseResult()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            result.issues.append(VaultImportIssue(code: .malformedJSON, message: "JSON 解析失败，文件可能已损坏。"))
            return result
        }
        guard let db = jsonObject(object["db"]), let entries = db["entries"] as? [Any] else {
            result.issues.append(VaultImportIssue(code: .malformedJSON, message: "缺少 db.entries 数组。"))
            return result
        }
        result.sourceItemCount = entries.count

        for (index, raw) in entries.enumerated() {
            guard let entry = raw as? [String: Any] else {
                result.issues.append(issue(index, code: .invalidField, message: "条目不是 JSON 对象，已跳过。"))
                continue
            }
            let type = (jsonString(entry["type"]) ?? "totp").lowercased()
            guard type == "totp" || type == "hotp" else {
                result.issues.append(issue(
                    index,
                    code: .unsupportedItemKind,
                    field: "type",
                    message: "第 \(index + 1) 条的类型 \(type) 暂不支持导入（仅支持 TOTP/HOTP），已跳过。"
                ))
                continue
            }
            let name = jsonString(entry["name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else {
                result.issues.append(issue(index, code: .missingRequiredField, field: "name", message: "第 \(index + 1) 条缺少 name，已跳过。"))
                continue
            }
            let info = jsonObject(entry["info"]) ?? [:]
            guard let rawSecret = jsonString(info["secret"]),
                  let secret = CredentialExchangeCodec.Base32.normalizedSecret(rawSecret) else {
                result.issues.append(issue(
                    index,
                    code: .invalidField,
                    field: "info.secret",
                    message: "第 \(index + 1) 条的密钥缺失或不是合法的 Base32，已跳过。"
                ))
                continue
            }
            let algorithm = normalizeAlgorithm(jsonString(info["algo"]))
            let digits = clamp(jsonInt(info["digits"]) ?? 6, 1...10)
            let period = clamp(jsonInt(info["period"]) ?? 30, 1...3600)
            let counter = max(0, jsonInt(info["counter"]) ?? 0)
            let otpType = type == "hotp" ? "hotp" : "totp"

            result.items.append(VaultTransferItem(
                draft: .totp(LocalTotpEntryDraft(
                    title: name,
                    secret: secret,
                    issuer: jsonString(entry["issuer"]) ?? "",
                    accountName: "",
                    period: UInt32(period),
                    digits: UInt32(digits),
                    algorithm: algorithm,
                    otpType: otpType,
                    counter: UInt64(counter)
                )),
                sourceIndex: index,
                sourceID: jsonString(entry["uuid"])
            ))
        }
        return result
    }
}

// MARK: - Stratum 明文 JSON

enum VaultStratumJSONImporter {
    static func parse(data: Data) -> VaultImportParseResult {
        var result = VaultImportParseResult()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            result.issues.append(VaultImportIssue(code: .malformedJSON, message: "JSON 解析失败，文件可能已损坏。"))
            return result
        }
        guard let authenticators = object["Authenticators"] as? [Any] else {
            result.issues.append(VaultImportIssue(code: .malformedJSON, message: "缺少 Authenticators 数组。"))
            return result
        }
        result.sourceItemCount = authenticators.count

        for (index, raw) in authenticators.enumerated() {
            guard let entry = raw as? [String: Any] else {
                result.issues.append(issue(index, code: .invalidField, message: "条目不是 JSON 对象，已跳过。"))
                continue
            }
            let type = jsonInt(entry["Type"]) ?? 2
            let issuer = jsonString(entry["Issuer"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let username = jsonString(entry["Username"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = !issuer.isEmpty ? issuer : (username.isEmpty ? "验证器 \(index + 1)" : username)

            guard type == 1 || type == 2 else {
                let typeName: String
                switch type {
                case 3: typeName = "MOTP"
                case 4: typeName = "Steam"
                case 5: typeName = "Yandex"
                default: typeName = "\(type)"
                }
                result.issues.append(issue(
                    index,
                    code: .unsupportedItemKind,
                    field: "Type",
                    message: "第 \(index + 1) 条的类型 \(typeName) 暂不支持导入（仅支持标准 TOTP/HOTP），已跳过。"
                ))
                continue
            }
            guard let rawSecret = jsonString(entry["Secret"]),
                  let secret = CredentialExchangeCodec.Base32.normalizedSecret(rawSecret) else {
                result.issues.append(issue(
                    index,
                    code: .invalidField,
                    field: "Secret",
                    message: "第 \(index + 1) 条的密钥缺失或不是合法的 Base32，已跳过。"
                ))
                continue
            }

            let algorithm = normalizeAlgorithm(jsonInt(entry["Algorithm"]).map { "\($0)" })
            let digits = clamp(jsonInt(entry["Digits"]) ?? 6, 1...10)
            let period = clamp(jsonInt(entry["Period"]) ?? 30, 1...3600)
            let counter = max(0, jsonInt(entry["Counter"]) ?? 0)
            let otpType = type == 1 ? "hotp" : "totp"

            var customFields: [VaultCustomField] = []
            if let pin = jsonString(entry["Pin"])?.trimmingCharacters(in: .whitespacesAndNewlines), !pin.isEmpty {
                customFields.append(VaultCustomField(label: "PIN", kind: .hiddenText, value: pin, order: 0))
                result.issues.append(issue(
                    index,
                    code: .skippedValue,
                    field: "Pin",
                    message: "第 \(index + 1) 条的 PIN 已作为隐藏自定义字段保留，但生成的验证码可能与原 App 不同。"
                ))
            }

            result.items.append(VaultTransferItem(
                draft: .totp(LocalTotpEntryDraft(
                    title: title,
                    secret: secret,
                    issuer: issuer,
                    accountName: username,
                    period: UInt32(period),
                    digits: UInt32(digits),
                    algorithm: algorithm,
                    otpType: otpType,
                    counter: UInt64(counter)
                )),
                customFields: customFields,
                sourceIndex: index,
                sourceID: jsonString(entry["Id"])
            ))
        }
        return result
    }
}

// MARK: - Monica JSON（自有的可往返格式）

enum VaultMonicaJSONImporter {
    static func parse(data: Data) -> VaultImportParseResult {
        var result = VaultImportParseResult()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            result.issues.append(VaultImportIssue(code: .malformedJSON, message: "JSON 解析失败，文件可能已损坏。"))
            return result
        }
        guard let schemaVersion = jsonInt(object["schemaVersion"]) else {
            result.issues.append(VaultImportIssue(
                sourceIndex: nil,
                code: .missingRequiredField,
                field: "schemaVersion",
                message: "缺少 schemaVersion，无法确认文件版本。"
            ))
            return result
        }
        guard schemaVersion == VaultExportEngine.schemaVersion else {
            result.issues.append(VaultImportIssue(
                sourceIndex: nil,
                code: .unsupportedVersion,
                field: "schemaVersion",
                message: "不支持的 schemaVersion \(schemaVersion)，本 App 只支持 \(VaultExportEngine.schemaVersion)。"
            ))
            return result
        }
        guard let rawItems = object["items"] as? [Any] else {
            result.issues.append(VaultImportIssue(code: .malformedJSON, message: "缺少 items 数组。"))
            return result
        }
        result.sourceItemCount = rawItems.count

        let columns = VaultCSVCodec.columns
        let headerIndex = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($0.element, $0.offset) })

        for (index, raw) in rawItems.enumerated() {
            guard let itemObject = raw as? [String: Any] else {
                result.issues.append(issue(index, code: .invalidField, message: "第 \(index + 1) 条不是 JSON 对象，已跳过。"))
                continue
            }
            var csvIssues: [VaultCSVImportIssue] = []
            var record = csvRecord(from: itemObject, columns: columns, headerIndex: headerIndex)
            guard let draft = VaultCSVCodec.parseItem(record: &record, rowNumber: index + 1, issues: &csvIssues) else {
                result.issues.append(contentsOf: csvIssues.map { convertedIssue($0) })
                continue
            }
            result.issues.append(contentsOf: csvIssues.map { convertedIssue($0) })

            var customFields: [VaultCustomField] = []
            if let rawFields = itemObject["customFields"] as? [Any] {
                customFields = parseCustomFields(rawFields)
            }
            result.items.append(VaultTransferItem(
                draft: draft,
                customFields: customFields,
                sourceIndex: index,
                sourceID: jsonString(itemObject["sourceID"])
            ))
        }
        return result
    }

    private static func csvRecord(
        from object: [String: Any],
        columns: [String],
        headerIndex: [String: Int]
    ) -> CSVRecord {
        var row = [String](repeating: "", count: columns.count)
        for (key, value) in object {
            guard let columnIndex = headerIndex[key] else { continue }
            switch key {
            case "urls":
                if let urls = value as? [Any] {
                    row[columnIndex] = urls
                        .compactMap { jsonString($0) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                } else if let urls = jsonString(value) {
                    row[columnIndex] = urls
                }
            default:
                if let stringValue = jsonString(value) {
                    row[columnIndex] = stringValue
                }
            }
        }
        if let titleIndex = headerIndex["title"] {
            row[titleIndex] = row[titleIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return CSVRecord(row: row, headerIndex: headerIndex)
    }

    private static func parseCustomFields(_ rawFields: [Any]) -> [VaultCustomField] {
        var fields: [VaultCustomField] = []
        for raw in rawFields {
            guard let dict = raw as? [String: Any] else { continue }
            let label = jsonString(dict["label"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let value = jsonString(dict["value"]) ?? ""
            guard !label.isEmpty else { continue }
            let kind = VaultCustomFieldKind(rawValue: jsonString(dict["kind"]) ?? "") ?? .text
            fields.append(VaultCustomField(label: label, kind: kind, value: value, order: fields.count))
        }
        return fields
    }
}

// MARK: - CSV 导入（Monica 原生 / 通用列映射）

enum VaultCSVColumnMapping {
    static let titleAliases: Set<String> = ["title", "name", "item", "account", "site", "service"]
    static let usernameAliases: Set<String> = ["username", "user", "login", "login_username", "email", "account_name"]
    static let passwordAliases: Set<String> = ["password", "pass", "pwd", "login_password", "secret"]
    static let urlAliases: Set<String> = ["url", "uri", "website", "web", "login_uri", "login_url", "link"]
    static let notesAliases: Set<String> = ["notes", "note", "comment", "comments", "memo", "remarks"]
    static let otpAliases: Set<String> = ["otpauth", "otp", "totp", "login_totp", "otp_url", "one_time_password"]
    static let folderAliases: Set<String> = ["tags", "folder", "folder_name", "group", "category", "collection"]

    enum Field: CaseIterable {
        case title
        case username
        case password
        case url
        case notes
        case otp
        case folder

        var aliases: [String] {
            switch self {
            case .title: return Array(titleAliases)
            case .username: return Array(usernameAliases)
            case .password: return Array(passwordAliases)
            case .url: return Array(urlAliases)
            case .notes: return Array(notesAliases)
            case .otp: return Array(otpAliases)
            case .folder: return Array(folderAliases)
            }
        }
    }

    static func columnIndex(for field: Field, header: [String]) -> Int? {
        let aliases = field.aliases
        for (index, name) in header.enumerated() where aliases.contains(name) {
            return index
        }
        return nil
    }
}

enum VaultCSVTransferImporter {
    static func parseMonicaCSV(data: Data) -> VaultImportParseResult {
        var result = VaultImportParseResult()
        guard let text = VaultImportDetector.decodedText(from: data) else {
            result.issues.append(VaultImportIssue(code: .malformedCSV, message: "文件不是 UTF-8 文本。"))
            return result
        }
        let rows: [[String]]
        do {
            rows = try VaultCSVCodec.parseRows(text)
        } catch {
            result.issues.append(VaultImportIssue(code: .malformedCSV, message: "CSV 解析失败：引号未闭合或内容被截断。"))
            return result
        }
        guard let headerRow = rows.first else {
            result.issues.append(VaultImportIssue(code: .malformedCSV, message: "CSV 缺少表头。"))
            return result
        }
        let header = headerRow.map(VaultImportDetector.normalizedColumnName)
        var headerIndex: [String: Int] = [:]
        for (index, name) in header.enumerated() where headerIndex[name] == nil {
            headerIndex[name] = index
        }
        // 归一化表头会改写大小写，这里同时登记原始表头名，便于按驼峰键读取自有列。
        for (index, raw) in headerRow.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, headerIndex[trimmed] == nil {
                headerIndex[trimmed] = index
            }
        }
        guard headerIndex["kind"] != nil else {
            result.issues.append(VaultImportIssue(code: .missingKindColumn, message: "缺少 kind 列，无法判断条目类型。"))
            return result
        }

        var csvIssues: [VaultCSVImportIssue] = []
        for (offset, row) in rows.dropFirst().enumerated() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                continue
            }
            result.sourceItemCount += 1
            let rowNumber = offset + 2
            var record = CSVRecord(row: row, headerIndex: headerIndex)
            guard let draft = VaultCSVCodec.parseItem(record: &record, rowNumber: rowNumber, issues: &csvIssues) else {
                continue
            }
            var customFields: [VaultCustomField] = []
            if let payload = VaultCustomFieldPayload.decode(record.value("customFields")) {
                customFields = payload
            } else if !record.value("customFields").isEmpty {
                result.issues.append(VaultImportIssue(
                    sourceIndex: offset,
                    code: .invalidField,
                    field: "customFields",
                    message: "第 \(rowNumber) 条的自定义字段不是合法 JSON，已忽略。"
                ))
            }
            result.items.append(VaultTransferItem(
                draft: draft,
                customFields: customFields,
                sourceIndex: offset
            ))
        }
        result.issues.append(contentsOf: csvIssues.map { convertedIssue($0) })
        return result
    }

    static func parseMappedCSV(data: Data, sourceFormat: VaultImportSourceFormat) -> VaultImportParseResult {
        var result = VaultImportParseResult()
        guard let text = VaultImportDetector.decodedText(from: data) else {
            result.issues.append(VaultImportIssue(code: .malformedCSV, message: "文件不是 UTF-8 文本。"))
            return result
        }
        let rows: [[String]]
        do {
            rows = try VaultCSVCodec.parseRows(text)
        } catch {
            result.issues.append(VaultImportIssue(code: .malformedCSV, message: "CSV 解析失败：引号未闭合或内容被截断。"))
            return result
        }
        guard let headerRow = rows.first else {
            result.issues.append(VaultImportIssue(code: .malformedCSV, message: "CSV 缺少表头。"))
            return result
        }
        let header = headerRow.map(VaultImportDetector.normalizedColumnName)
        var indexes: [VaultCSVColumnMapping.Field: Int] = [:]
        for field in VaultCSVColumnMapping.Field.allCases {
            indexes[field] = VaultCSVColumnMapping.columnIndex(for: field, header: header)
        }
        guard indexes[.title] != nil || indexes[.url] != nil else {
            result.issues.append(VaultImportIssue(
                sourceIndex: nil,
                code: .unrecognizedFormat,
                message: "\(sourceFormat.displayName) 表头里没有标题或网址列，无法映射。"
            ))
            return result
        }

        for (offset, row) in rows.dropFirst().enumerated() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                continue
            }
            result.sourceItemCount += 1
            func value(_ field: VaultCSVColumnMapping.Field) -> String {
                guard let index = indexes[field], index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let url = value(.url)
            var title = value(.title)
            if title.isEmpty, let host = URLComponents(string: url)?.host {
                title = host
            }
            guard !title.isEmpty || !url.isEmpty else {
                result.issues.append(VaultImportIssue(
                    sourceIndex: offset,
                    code: .missingRequiredField,
                    field: "title",
                    message: "第 \(offset + 2) 行既没有标题也没有网址，已跳过。"
                ))
                continue
            }
            if title.isEmpty {
                title = url
            }

            let username = value(.username)
            let password = value(.password)
            let notes = value(.notes)
            let folder = value(.folder)

            result.items.append(VaultTransferItem(
                draft: .login(LocalLoginEntryDraft(
                    title: title,
                    username: username,
                    password: password,
                    url: url,
                    notes: notes
                )),
                customFields: folder.isEmpty
                    ? []
                    : [VaultCustomField(label: "Folder", kind: .text, value: folder, order: 0)],
                sourceIndex: offset
            ))

            let otpValue = value(.otp)
            guard !otpValue.isEmpty else { continue }
            if let otp = VaultOTPAuthURI.parse(otpValue) {
                result.items.append(VaultTransferItem(
                    draft: .totp(LocalTotpEntryDraft(
                        title: title,
                        secret: otp.secret,
                        issuer: otp.issuer,
                        accountName: otp.accountName.isEmpty ? username : otp.accountName,
                        period: UInt32(otp.period),
                        digits: UInt32(otp.digits),
                        algorithm: otp.algorithm,
                        otpType: otp.otpType,
                        counter: UInt64(otp.counter)
                    )),
                    sourceIndex: offset
                ))
            } else {
                result.issues.append(VaultImportIssue(
                    sourceIndex: offset,
                    code: .invalidField,
                    field: "otp",
                    message: "第 \(offset + 2) 行的验证器字段不是合法的 otpauth 链接，已跳过该验证器。"
                ))
            }
        }
        return result
    }
}

// MARK: - otpauth 链接

struct VaultOTPAuthURI: Equatable {
    let otpType: String
    let issuer: String
    let accountName: String
    let secret: String
    let digits: Int
    let period: Int
    let counter: Int
    let algorithm: String

    /// 解析 `otpauth://totp/Issuer:account?secret=...`；非 otpauth 链接返回 nil。
    static func parse(_ raw: String) -> VaultOTPAuthURI? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("otpauth://"),
              let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased() else {
            return nil
        }
        let otpType: String
        switch host {
        case "totp": otpType = "totp"
        case "hotp": otpType = "hotp"
        default: return nil
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value, !value.isEmpty else { continue }
            query[item.name.lowercased()] = value
        }
        guard let rawSecret = query["secret"],
              let secret = CredentialExchangeCodec.Base32.normalizedSecret(rawSecret) else {
            return nil
        }

        // path 形如 "/Issuer:account"，百分号编码需要还原。
        var label = components.path
        if label.hasPrefix("/") {
            label.removeFirst()
        }
        label = label.removingPercentEncoding ?? label
        let issuerFromLabel: String
        let accountFromLabel: String
        if let range = label.range(of: ":") {
            issuerFromLabel = String(label[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            accountFromLabel = String(label[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            issuerFromLabel = ""
            accountFromLabel = label.trimmingCharacters(in: .whitespaces)
        }

        let issuer = (query["issuer"] ?? issuerFromLabel).trimmingCharacters(in: .whitespaces)
        let digits = clamp(Int(query["digits"] ?? "") ?? 6, 1...10)
        let period = clamp(Int(query["period"] ?? "") ?? 30, 1...3600)
        let counter = max(0, Int(query["counter"] ?? "") ?? 0)
        let algorithm = normalizeAlgorithm(query["algorithm"])

        return VaultOTPAuthURI(
            otpType: otpType,
            issuer: issuer,
            accountName: accountFromLabel,
            secret: secret,
            digits: digits,
            period: period,
            counter: counter,
            algorithm: algorithm
        )
    }
}

// MARK: - 自定义字段载荷（CSV 单元格 / JSON 数组共用）

public enum VaultCustomFieldPayload {
    /// 编码成紧凑 JSON 数组，便于放进单个 CSV 单元格。
    public static func encode(_ fields: [VaultCustomField]) -> String {
        guard !fields.isEmpty else { return "" }
        let objects: [[String: Any]] = fields.enumerated().map { index, field in
            [
                "label": field.label,
                "kind": field.kind.rawValue,
                "value": field.value,
                "order": index
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 空单元格返回 `[]`；格式非法返回 nil，由调用方决定是否报错。
    public static func decode(_ raw: String) -> [VaultCustomField]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8),
              let objects = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }
        var fields: [VaultCustomField] = []
        for (index, raw) in objects.enumerated() {
            guard let dict = raw as? [String: Any] else { continue }
            let label = jsonString(dict["label"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let value = jsonString(dict["value"]) ?? ""
            guard !label.isEmpty else { continue }
            let kind = VaultCustomFieldKind(rawValue: jsonString(dict["kind"]) ?? "") ?? .text
            fields.append(VaultCustomField(label: label, kind: kind, value: value, order: index))
        }
        return fields
    }
}

// MARK: - 导出

public struct VaultExportOptions: Sendable, Equatable {
    public var format: VaultExportFormat
    public var includeCustomFields: Bool
    /// 非空时用 `MONICA_ENC_V1` 信封加密整个导出文件。
    public var encryptionPassword: String?

    public init(
        format: VaultExportFormat = .csv,
        includeCustomFields: Bool = true,
        encryptionPassword: String? = nil
    ) {
        self.format = format
        self.includeCustomFields = includeCustomFields
        self.encryptionPassword = encryptionPassword
    }
}

public struct VaultExportArtifact: Sendable, Equatable {
    public let data: Data
    public let fileName: String
    public let format: VaultExportFormat
    public let isEncrypted: Bool

    public init(data: Data, fileName: String, format: VaultExportFormat, isEncrypted: Bool) {
        self.data = data
        self.fileName = fileName
        self.format = format
        self.isEncrypted = isEncrypted
    }
}

public enum VaultExportError: Error, Sendable, Equatable, LocalizedError {
    case emptyPassword
    case serializationFailed

    public var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return String(localized: "加密导出需要非空密码。")
        case .serializationFailed:
            return String(localized: "导出内容无法序列化。")
        }
    }
}

public enum VaultExportEngine {
    public static let schemaVersion = 1
    public static let formatIdentifier = "monica-vault"

    /// 只做纯数据转换；写文件、确认明文导出都由 App 层负责。
    public static func export(
        items: [VaultTransferItem],
        options: VaultExportOptions = VaultExportOptions(),
        now: Date = Date()
    ) throws -> VaultExportArtifact {
        let rawData: Data
        switch options.format {
        case .csv:
            var csvItems = items
            if !options.includeCustomFields {
                csvItems = items.map { VaultTransferItem(draft: $0.draft, customFields: [], sourceIndex: $0.sourceIndex, sourceID: $0.sourceID) }
            }
            rawData = Data(VaultCSVCodec.exportTransferItems(csvItems).utf8)
        case .json:
            rawData = try jsonData(items: items, includeCustomFields: options.includeCustomFields, now: now)
        }

        let isEncrypted = options.encryptionPassword != nil
        var output = rawData
        if let password = options.encryptionPassword {
            // 传了密码却为空，说明调用方以为会加密：直接报错，绝不静默降级成明文。
            guard !password.isEmpty else {
                throw VaultExportError.emptyPassword
            }
            do {
                output = try AndroidBackupCodec.encryptPayload(rawData, password: password)
            } catch {
                throw VaultExportError.serializationFailed
            }
        }
        return VaultExportArtifact(
            data: output,
            fileName: suggestedFileName(format: options.format, now: now, encrypted: isEncrypted),
            format: options.format,
            isEncrypted: isEncrypted
        )
    }

    static func suggestedFileName(format: VaultExportFormat, now: Date, encrypted: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        let suffix = encrypted ? ".enc" : ""
        return "Monica-Vault-\(stamp).\(format.fileExtension)\(suffix)"
    }

    private static func jsonData(
        items: [VaultTransferItem],
        includeCustomFields: Bool,
        now: Date
    ) throws -> Data {
        let numericColumns: Set<String> = ["period", "digits", "counter", "maxViews"]
        let jsonItems: [[String: Any]] = items.map { item in
            var values = VaultCSVCodec.rowValues(for: item.draft)
            let urlValues = values["urls"]?
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } ?? []
            values.removeValue(forKey: "urls")

            var object: [String: Any] = [:]
            for (key, value) in values where !value.isEmpty {
                if numericColumns.contains(key), let number = Int(value) {
                    object[key] = number
                } else if key == "hidden" {
                    object[key] = (value == "true" || value == "1")
                } else {
                    object[key] = value
                }
            }
            if !urlValues.isEmpty {
                object["urls"] = urlValues
            }
            if includeCustomFields, !item.customFields.isEmpty {
                object["customFields"] = item.customFields.enumerated().map { _, field in
                    [
                        "label": field.label,
                        "kind": field.kind.rawValue,
                        "value": field.value
                    ]
                }
            }
            return object
        }

        let root: [String: Any] = [
            "format": formatIdentifier,
            "schemaVersion": schemaVersion,
            "exportedAt": now.formatted(.iso8601),
            "itemCount": items.count,
            "items": jsonItems
        ]
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            throw VaultExportError.serializationFailed
        }
        return data
    }
}

public enum VaultExportEncryption {
    public static func isEncrypted(_ data: Data) -> Bool {
        AndroidBackupCodec.isEncryptedPayload(data)
    }

    public static func encrypt(_ payload: Data, password: String) throws -> Data {
        guard !password.isEmpty else {
            throw VaultExportError.emptyPassword
        }
        return try AndroidBackupCodec.encryptPayload(payload, password: password)
    }

    public static func decrypt(_ payload: Data, password: String) throws -> Data {
        try AndroidBackupCodec.decryptPayload(payload, password: password)
    }
}

// MARK: - JSON 辅助

private func jsonString(_ value: Any?) -> String? {
    if let value = value as? String {
        return value
    }
    if let value = value as? NSNumber {
        return value.stringValue
    }
    return nil
}

private func jsonInt(_ value: Any?) -> Int? {
    if let value = value as? Int {
        return value
    }
    if let value = value as? NSNumber {
        return value.intValue
    }
    if let value = value as? String {
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
}

private func jsonBool(_ value: Any?) -> Bool? {
    if let value = value as? Bool {
        return value
    }
    if let value = value as? NSNumber {
        return value.boolValue
    }
    if let value = value as? String {
        switch value.lowercased() {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return nil
        }
    }
    return nil
}

private func jsonObject(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

private func issue(
    _ index: Int,
    code: VaultImportIssueCode,
    field: String? = nil,
    message: String
) -> VaultImportIssue {
    VaultImportIssue(sourceIndex: index, code: code, field: field, message: message)
}

private func convertedIssue(_ issue: VaultCSVImportIssue) -> VaultImportIssue {
    VaultImportIssue(
        sourceIndex: max(0, issue.row - 2),
        code: convertedIssueCode(issue.code),
        field: issue.field,
        message: issue.message
    )
}

private func convertedIssueCode(_ code: VaultCSVImportIssueCode) -> VaultImportIssueCode {
    switch code {
    case .emptyCSV, .malformedCSV:
        return .malformedCSV
    case .missingKindColumn:
        return .missingKindColumn
    case .unsupportedKind:
        return .unsupportedItemKind
    case .missingRequiredField:
        return .missingRequiredField
    case .invalidNumber, .invalidBoolean, .invalidFieldFormat:
        return .invalidField
    }
}

private func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
    min(max(value, range.lowerBound), range.upperBound)
}

private func normalizeAlgorithm(_ raw: String?) -> String {
    switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
    case "SHA256", "1":
        return "SHA256"
    case "SHA512", "2":
        return "SHA512"
    case "MD5", "3":
        // MD5 不是标准 TOTP 算法，降级为 SHA1 并依赖调用方提示。
        return "SHA1"
    default:
        return "SHA1"
    }
}
