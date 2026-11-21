import Foundation

// MARK: - 常用账号模板（issue #127）
//
// 设计要点：
// - 模板只描述「创建一个登录条目时该预填什么」，因此模型里**没有任何密码/密钥字段**。
//   自定义字段也只允许普通文本/链接/日期，`hiddenText`（受保护值）在模板里一律拒绝，
//   否则模板会变成密码的搬运工，违背 issue 的硬要求。
// - 模板记录和条目自定义字段、文件夹层级一样放在加密侧表的锚点工程里，
//   随保险库一起加密，不写 UserDefaults、不落明文文件。
// - 内置模板是代码常量（不是用户数据），用户只能复制成自定义模板后再改。

/// 模板相关的错误。所有文案都是可读的中文，App 直接展示 `localizedDescription`。
public enum AccountTemplateError: Error, Sendable, Equatable, LocalizedError {
    /// 标题去掉首尾空白后为空。
    case emptyTitle
    /// 标题超过 `AccountTemplateRules.maxTitleLength`。
    case titleTooLong(limit: Int)
    /// 默认网址条数超过 `AccountTemplateRules.maxURLCount`。
    case tooManyURLs(limit: Int)
    /// 默认网址不是合法的 http/https 绝对链接。
    case invalidURL(String)
    /// 自定义字段数量超过 `AccountTemplateRules.maxCustomFieldCount`。
    case tooManyCustomFields(limit: Int)
    /// 自定义字段没有名字（去掉空白后为空）。
    case emptyCustomFieldLabel
    /// 自定义字段名字太长。
    case customFieldLabelTooLong(limit: Int)
    /// 模板里出现 `hiddenText` 受保护字段。
    case protectedCustomFieldUnsupported
    /// 备注超过 `AccountTemplateRules.maxNotesLength`。
    case notesTooLong(limit: Int)
    /// 用户名占位超过 `AccountTemplateRules.maxUsernamePlaceholderLength`。
    case usernamePlaceholderTooLong(limit: Int)
    /// 要改/删的模板不存在。
    case templateNotFound
    /// 内置模板只读。
    case builtinTemplateReadOnly
    /// 自定义模板数量到达上限。
    case templateLimitReached(limit: Int)
    /// 当前存储引擎没有提供模板侧表能力。
    case engineUnavailable
    /// 锚点工程不可用。
    case anchorUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptyTitle:
            return "模板标题不能为空。"
        case .titleTooLong(let limit):
            return "模板标题最多 \(limit) 个字符。"
        case .tooManyURLs(let limit):
            return "模板最多保存 \(limit) 个默认网址。"
        case .invalidURL(let value):
            return "默认网址「\(value)」不是有效的 http/https 链接。"
        case .tooManyCustomFields(let limit):
            return "模板最多保存 \(limit) 个自定义字段。"
        case .emptyCustomFieldLabel:
            return "自定义字段需要有名字。"
        case .customFieldLabelTooLong(let limit):
            return "自定义字段名字最多 \(limit) 个字符。"
        case .protectedCustomFieldUnsupported:
            return "模板不能包含隐藏文本字段，以免把密码或密钥带进模板。"
        case .notesTooLong(let limit):
            return "模板备注最多 \(limit) 个字符。"
        case .usernamePlaceholderTooLong(let limit):
            return "用户名占位提示最多 \(limit) 个字符。"
        case .templateNotFound:
            return "模板不存在，可能已经被删除。"
        case .builtinTemplateReadOnly:
            return "内置模板不能直接修改，请先复制为自定义模板。"
        case .templateLimitReached(let limit):
            return "自定义模板最多 \(limit) 个。"
        case .engineUnavailable:
            return "当前存储引擎不支持常用账号模板。"
        case .anchorUnavailable:
            return "模板索引暂不可用。"
        }
    }
}

/// 模板的数值上限。全部是纯常量，方便测试固定向量。
public enum AccountTemplateRules {
    /// 标题最大字素数。
    public static let maxTitleLength = 80
    /// 默认网址最大条数（和 `LoginEntryURLRules.maximumURLCount` 保持同一数量级）。
    public static let maxURLCount = 10
    /// 备注最大字素数。
    public static let maxNotesLength = 4096
    /// 用户名占位提示最大字素数。
    public static let maxUsernamePlaceholderLength = 120
    /// 自定义字段最大个数。
    public static let maxCustomFieldCount = 20
    /// 自定义字段名字最大字素数。
    public static let maxCustomFieldLabelLength = 120
    /// 自定义字段默认值最大字素数。
    public static let maxCustomFieldValueLength = 1024
    /// 自定义模板最大条数（内置模板不计入）。
    public static let maxCustomTemplateCount = 200
}

// MARK: - 模板自定义字段

/// 模板里的一条「默认自定义字段」。
///
/// 只保存将来要创建的字段的骨架（名字、类型、默认值），不保存条目的实际值。
/// 类型只允许 `text`/`url`/`date`：`hiddenText` 是受保护类型，模板一旦能存它，
/// 就等于允许把密码写进可导出的 JSON。
public struct AccountTemplateCustomField: Sendable, Equatable, Hashable {
    public var label: String
    public var kind: VaultCustomFieldKind
    public var defaultValue: String

    public init(label: String, kind: VaultCustomFieldKind = .text, defaultValue: String = "") {
        self.label = label
        self.kind = kind
        self.defaultValue = defaultValue
    }

    public var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 归一化：去空白、拒绝受保护类型、校验长度与链接格式。
    public func normalized() throws -> AccountTemplateCustomField {
        let label = trimmedLabel
        guard !label.isEmpty else {
            throw AccountTemplateError.emptyCustomFieldLabel
        }
        guard label.count <= AccountTemplateRules.maxCustomFieldLabelLength else {
            throw AccountTemplateError.customFieldLabelTooLong(limit: AccountTemplateRules.maxCustomFieldLabelLength)
        }
        guard !kind.isProtected else {
            throw AccountTemplateError.protectedCustomFieldUnsupported
        }
        var value = defaultValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count > AccountTemplateRules.maxCustomFieldValueLength {
            value = String(value.prefix(AccountTemplateRules.maxCustomFieldValueLength))
        }
        if kind == .url, !value.isEmpty {
            guard LoginEntryURLRules.isValid(value) else {
                throw AccountTemplateError.invalidURL(value)
            }
        }
        return AccountTemplateCustomField(label: label, kind: kind, defaultValue: value)
    }
}

// MARK: - 模板

/// 一条常用账号模板。
///
/// 保持 `Sendable` + 值类型：所有写操作都会先 `normalized()` 再落库，
/// 这样侧表里永远不会出现超长标题或受保护字段。
public struct AccountTemplate: Sendable, Equatable, Hashable, Identifiable {
    /// 侧表格式版本。
    public static let currentSchemaVersion = 1

    /// 侧表记录类型：MDBX FFI 只接受固定类型白名单，所以和文件夹记录、条目扩展
    /// 一样借用 `document-ref`，靠 entryKind 区分具体用途。
    public static let entryType = "document-ref"
    /// 侧表记录种类：模板单独一种，不会和文件夹记录、条目自定义字段混在一起。
    public static let entryKind = "account-template"

    public var schemaVersion: Int
    public var templateID: String
    public var title: String
    /// 模板适用的条目类型。目前内置模板全部是 `.login`。
    public var itemKind: UnifiedVaultItemKind
    /// 默认网址列表（有序、去重、只保留合法的 http/https 链接）。
    public var defaultURLs: [String]
    /// 用户名输入框的占位提示（例如「Apple ID 邮箱」）。
    ///
    /// 注意：这是**占位提示**而不是要写入的账号值，套用模板时不会写进用户名输入框，
    /// 否则会诱导用户把示例文本当成自己的账号保存。
    public var usernamePlaceholder: String
    /// 默认备注。
    public var defaultNotes: String
    /// 默认自定义字段（只含骨架，不含真实值）。
    public var defaultCustomFields: [AccountTemplateCustomField]
    /// 是否提示该服务建议开启两步验证。
    ///
    /// 登录条目本身没有 TOTP 绑定字段（TOTP 是独立条目），所以这里只表示「提示」，
    /// 套用模板时不会自动创建或绑定验证器条目。
    public var requiresTOTP: Bool
    /// 自定义模板之间的排序权重；内置模板忽略这个值。
    public var sortOrder: Int
    /// 内置模板（代码常量，只读）。
    public var isBuiltin: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { templateID }

    public init(
        schemaVersion: Int = AccountTemplate.currentSchemaVersion,
        templateID: String = UUID().uuidString,
        title: String,
        itemKind: UnifiedVaultItemKind = .login,
        defaultURLs: [String] = [],
        usernamePlaceholder: String = "",
        defaultNotes: String = "",
        defaultCustomFields: [AccountTemplateCustomField] = [],
        requiresTOTP: Bool = false,
        sortOrder: Int = 0,
        isBuiltin: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.templateID = templateID
        self.title = title
        self.itemKind = itemKind
        self.defaultURLs = defaultURLs
        self.usernamePlaceholder = usernamePlaceholder
        self.defaultNotes = defaultNotes
        self.defaultCustomFields = defaultCustomFields
        self.requiresTOTP = requiresTOTP
        self.sortOrder = sortOrder
        self.isBuiltin = isBuiltin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 展示用标题：历史数据里可能存着空白标题，这里兜一层。
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名模板" : trimmed
    }

    /// 列表副标题：优先展示第一个网址的 host，没有网址时给一句说明。
    public var urlSummary: String {
        guard let first = defaultURLs.first else {
            return "未预设网址"
        }
        if let host = URLComponents(string: first)?.host, !host.isEmpty {
            return host
        }
        return first
    }

    /// 归一化：去空白、去重、校验长度与链接、重排字段顺序。
    public func normalized(now: Date = Date()) throws -> AccountTemplate {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw AccountTemplateError.emptyTitle
        }
        guard trimmedTitle.count <= AccountTemplateRules.maxTitleLength else {
            throw AccountTemplateError.titleTooLong(limit: AccountTemplateRules.maxTitleLength)
        }
        let notes = defaultNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard notes.count <= AccountTemplateRules.maxNotesLength else {
            throw AccountTemplateError.notesTooLong(limit: AccountTemplateRules.maxNotesLength)
        }
        let placeholder = usernamePlaceholder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard placeholder.count <= AccountTemplateRules.maxUsernamePlaceholderLength else {
            throw AccountTemplateError.usernamePlaceholderTooLong(limit: AccountTemplateRules.maxUsernamePlaceholderLength)
        }
        let urls = try Self.normalizedURLs(defaultURLs)
        let fields = try Self.normalizedCustomFields(defaultCustomFields)
        return AccountTemplate(
            schemaVersion: Self.currentSchemaVersion,
            templateID: templateID.trimmingCharacters(in: .whitespacesAndNewlines),
            title: trimmedTitle,
            itemKind: itemKind,
            defaultURLs: urls,
            usernamePlaceholder: placeholder,
            defaultNotes: notes,
            defaultCustomFields: fields,
            requiresTOTP: requiresTOTP,
            sortOrder: sortOrder,
            isBuiltin: isBuiltin,
            createdAt: createdAt,
            updatedAt: now
        )
    }

    /// 有序去重 + 合法性校验的默认网址列表。
    public static func normalizedURLs(_ candidates: [String]) throws -> [String] {
        let urls = LoginEntryURLRules.normalizedURLs(candidates)
        guard urls.count <= AccountTemplateRules.maxURLCount else {
            throw AccountTemplateError.tooManyURLs(limit: AccountTemplateRules.maxURLCount)
        }
        for url in urls {
            guard LoginEntryURLRules.isValid(url) else {
                throw AccountTemplateError.invalidURL(url)
            }
        }
        return urls
    }

    /// 自定义字段归一化：去空白、按名字去重（忽略大小写）、保留首次出现的顺序。
    public static func normalizedCustomFields(
        _ candidates: [AccountTemplateCustomField]
    ) throws -> [AccountTemplateCustomField] {
        guard candidates.count <= AccountTemplateRules.maxCustomFieldCount else {
            throw AccountTemplateError.tooManyCustomFields(limit: AccountTemplateRules.maxCustomFieldCount)
        }
        var seen = Set<String>()
        var result: [AccountTemplateCustomField] = []
        for candidate in candidates {
            // 空白字段名没有意义（编辑器里通常会留下一行空行），跳过而不是让整条模板保存失败。
            let trimmedLabel = candidate.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLabel.isEmpty else { continue }
            let normalized = try candidate.normalized()
            guard seen.insert(normalized.trimmedLabel.lowercased()).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    // MARK: 侧表载荷

    /// 宽容解码：缺字段、类型不符都回退到默认值，保证旧库/旧备份可读。
    ///
    /// 解析失败时退化成「只有 templateID」的记录而不是丢弃，否则一条坏数据
    /// 就能让整个模板列表少一条；标题为空时 UI 会显示「未命名模板」。
    public init?(payloadJSON: String, fallbackTemplateID: String) {
        guard !fallbackTemplateID.isEmpty || !payloadJSON.isEmpty else { return nil }
        let parsed = payloadJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let object = parsed ?? [:]
        let templateID = (object["templateID"] as? String) ?? fallbackTemplateID
        guard !templateID.isEmpty else { return nil }
        self.schemaVersion = (object["schemaVersion"] as? Int) ?? AccountTemplate.currentSchemaVersion
        self.templateID = templateID
        self.title = (object["title"] as? String) ?? ""
        self.itemKind = UnifiedVaultItemKind(rawValue: (object["itemKind"] as? String) ?? "") ?? .login
        self.defaultURLs = (object["defaultURLs"] as? [String]) ?? []
        self.usernamePlaceholder = (object["usernamePlaceholder"] as? String) ?? ""
        self.defaultNotes = (object["defaultNotes"] as? String) ?? ""
        self.defaultCustomFields = Self.customFields(from: object["defaultCustomFields"])
        self.requiresTOTP = (object["requiresTOTP"] as? Bool) ?? false
        self.sortOrder = (object["sortOrder"] as? Int) ?? 0
        self.isBuiltin = (object["isBuiltin"] as? Bool) ?? false
        let created = Self.date(from: object["createdAt"])
        let updated = Self.date(from: object["updatedAt"])
        self.createdAt = created ?? updated ?? Date(timeIntervalSince1970: 0)
        self.updatedAt = updated ?? self.createdAt
    }

    /// 解码自定义字段：跳过受保护类型与空名字，避免脏载荷把隐藏字段带进编辑器。
    private static func customFields(from raw: Any?) -> [AccountTemplateCustomField] {
        let items = raw as? [Any] ?? []
        var result: [AccountTemplateCustomField] = []
        for item in items {
            guard let dict = item as? [String: Any] else { continue }
            let label = ((dict["label"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            let kind = VaultCustomFieldKind(storageValue: dict["kind"] as? String)
            guard !kind.isProtected else { continue }
            let value = (dict["defaultValue"] as? String) ?? ""
            result.append(AccountTemplateCustomField(label: label, kind: kind, defaultValue: value))
            if result.count >= AccountTemplateRules.maxCustomFieldCount { break }
        }
        return result
    }

    private static func date(from raw: Any?) -> Date? {
        if let value = raw as? Double {
            return Date(timeIntervalSince1970: value)
        }
        if let value = raw as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        if let value = raw as? String {
            return ISO8601DateFormatter().date(from: value)
        }
        return nil
    }

    /// 侧表载荷（加密写入 MDBX）。
    public func payloadJSONString() throws -> String {
        let fields: [[String: Any]] = defaultCustomFields.map { field in
            [
                "label": field.label,
                "kind": field.kind.rawValue,
                "defaultValue": field.defaultValue
            ]
        }
        let object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "templateID": templateID,
            "title": title,
            "itemKind": itemKind.rawValue,
            "defaultURLs": defaultURLs,
            "usernamePlaceholder": usernamePlaceholder,
            "defaultNotes": defaultNotes,
            "defaultCustomFields": fields,
            "requiresTOTP": requiresTOTP,
            "sortOrder": sortOrder,
            "isBuiltin": isBuiltin,
            "createdAt": createdAt.timeIntervalSince1970,
            "updatedAt": updatedAt.timeIntervalSince1970
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        return json
    }

    /// 导入/导出用的字典形态（不含 isBuiltin/sortOrder，顺序由数组决定）。
    public func exportObject() -> [String: Any] {
        let fields: [[String: Any]] = defaultCustomFields.map { field in
            [
                "label": field.label,
                "kind": field.kind.rawValue,
                "defaultValue": field.defaultValue
            ]
        }
        return [
            "templateID": templateID,
            "title": title,
            "itemKind": itemKind.rawValue,
            "defaultURLs": defaultURLs,
            "usernamePlaceholder": usernamePlaceholder,
            "defaultNotes": defaultNotes,
            "defaultCustomFields": fields,
            "requiresTOTP": requiresTOTP
        ]
    }
}

// MARK: - 内置模板

/// 内置模板目录。全部是代码常量：不含密码/密钥，也不含真实账号。
public enum AccountTemplateCatalog {
    /// 内置模板的稳定 ID 前缀。导入时遇到这个前缀会换成新 ID，避免和代码常量撞车。
    public static let builtinIDPrefix = "builtin."

    /// 内置模板（按展示顺序）。覆盖 issue 要求的 8 类常用服务：
    /// Apple、Google、GitHub、Microsoft、银行、运营商、政务、邮箱。
    public static let builtins: [AccountTemplate] = [
        AccountTemplate(
            templateID: "builtin.apple",
            title: "Apple 账户",
            defaultURLs: ["https://appleid.apple.com/", "https://www.icloud.com/"],
            usernamePlaceholder: "Apple ID 邮箱",
            defaultNotes: "在「Apple ID 与安全性」里管理双重认证。恢复密钥请离线保存，不要写进模板。",
            defaultCustomFields: [
                AccountTemplateCustomField(label: "Apple ID 所在地区"),
                AccountTemplateCustomField(label: "受信任设备")
            ],
            requiresTOTP: true,
            sortOrder: 0,
            isBuiltin: true,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        ),
        AccountTemplate(
            templateID: "builtin.google",
            title: "Google 账户",
            defaultURLs: ["https://accounts.google.com/"],
            usernamePlaceholder: "Google 邮箱",
            defaultNotes: "建议开启两步验证，并把备用码保存在保险库里而不是模板里。",
            defaultCustomFields: [
                AccountTemplateCustomField(label: "辅助邮箱"),
                AccountTemplateCustomField(label: "备用码保存位置")
            ],
            requiresTOTP: true,
            sortOrder: 1,
            isBuiltin: true,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        ),
        AccountTemplate(
            templateID: "builtin.github",
            title: "GitHub",
            defaultURLs: ["https://github.com/login"],
            usernamePlaceholder: "GitHub 用户名或邮箱",
            defaultNotes: "建议启用双重验证并保存恢复码；SSH 私钥请使用单独的 SSH 密钥条目。",
            defaultCustomFields: [
                AccountTemplateCustomField(label: "所属组织")
            ],
            requiresTOTP: true,
            sortOrder: 2,
            isBuiltin: true,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        ),
        AccountTemplate(
            templateID: "builtin.microsoft",
            title: "Microsoft 账户",
            defaultURLs: ["https://login.microsoftonline.com/", "https://account.microsoft.com/"],
            usernamePlaceholder: "Microsoft 账户邮箱",
            defaultNotes: "工作/学校账户请向管理员确认登录地址；个人账户可在 account.microsoft.com 管理安全信息。",
            defaultCustomFields: [
                AccountTemplateCustomField(label: "租户或组织")
            ],
            requiresTOTP: true,
            sortOrder: 3,
            isBuiltin: true,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        ),
        AccountTemplate(
            templateID: "builtin.bank",
            title: "银行（通用）",
            defaultURLs: [],
            usernamePlaceholder: "银行卡号或网银用户名",
            defaultNotes: "各银行网银地址不同，请把实际登录地址填到「网站/网址」。支付密码、U 盾 PIN 请单独保存。",
            defaultCustomFields: [
                AccountTemplateCustomField(label: "开户行"),
                AccountTemplateCustomField(label: "预留手机号尾号")
            ],
            requiresTOTP: false,
            sortOrder: 4,
            isBuiltin: true,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        ),
        AccountTemplate(
            templateID: "builtin.carrier",
            title: "运营商（通用）",
            defaultURLs: [],
            usernamePlaceholder: "手机号或宽带账号",
            defaultNotes: "移动/联通/电信的网上营业厅地址不同，请填写实际网址。服务密码与登录密码分开保存。",
            defaultCustomFields: [
                AccountTemplateCustomField(label: "运营商"),
                AccountTemplateCustomField(label: "套餐或归属地")
            ],
            requiresTOTP: false,
            sortOrder: 5,
            isBuiltin: true,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        ),
        AccountTemplate(
            templateID: "builtin.government",
            title: "政务服务平台（通用）",
            defaultURLs: ["https://gjzwfw.www.gov.cn/"],
            usernamePlaceholder: "身份证号或手机号",
            defaultNotes: "各地政务平台地址不同，可按需替换。统一身份认证通常配合短信验证码使用。",
            defaultCustomFields: [
                AccountTemplateCustomField(label: "所属地区"),
                AccountTemplateCustomField(label: "认证方式")
            ],
            requiresTOTP: false,
            sortOrder: 6,
            isBuiltin: true,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        ),
        AccountTemplate(
            templateID: "builtin.email",
            title: "邮箱（通用）",
            defaultURLs: [],
            usernamePlaceholder: "name@example.com",
            defaultNotes: "网页版地址请按邮箱服务商填写；IMAP/SMTP 服务器与授权码提示可以放在自定义字段里，授权码本身不要写进模板。",
            defaultCustomFields: [
                AccountTemplateCustomField(label: "邮箱服务商"),
                AccountTemplateCustomField(label: "IMAP 服务器"),
                AccountTemplateCustomField(label: "SMTP 服务器")
            ],
            requiresTOTP: true,
            sortOrder: 7,
            isBuiltin: true,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    ]

    /// 某个条目类型可用的内置模板。
    public static func builtins(for kind: UnifiedVaultItemKind) -> [AccountTemplate] {
        builtins.filter { $0.itemKind == kind }
    }

    public static func isBuiltinTemplateID(_ templateID: String) -> Bool {
        templateID.hasPrefix(builtinIDPrefix)
    }
}

// MARK: - 套用模板（只填空字段）

/// 套用模板时编辑器里的现有内容。
public struct AccountTemplateFillDraft: Sendable, Equatable {
    public var title: String
    public var urls: [String]
    public var username: String
    public var notes: String
    public var customFieldLabels: [String]

    public init(
        title: String = "",
        urls: [String] = [],
        username: String = "",
        notes: String = "",
        customFieldLabels: [String] = []
    ) {
        self.title = title
        self.urls = urls
        self.username = username
        self.notes = notes
        self.customFieldLabels = customFieldLabels
    }
}

/// 套用模板的结果。
public struct AccountTemplateFillOutcome: Sendable, Equatable {
    public var title: String
    public var urls: [String]
    public var username: String
    public var notes: String
    /// 需要新增的自定义字段（已排除编辑器里已有的同名字段）。
    public var customFieldsToAdd: [AccountTemplateCustomField]
    /// 用户名输入框的占位提示。
    public var usernamePlaceholder: String
    /// 该模板建议开启两步验证。
    public var requiresTOTP: Bool
    /// 实际被填写的字段个数（标题/网址/备注各算一个）。
    public var filledFieldCount: Int

    public var hasChanges: Bool {
        filledFieldCount > 0 || !customFieldsToAdd.isEmpty
    }
}

/// 模板套用策略：**只填空白字段**，用户已经输入的内容一律保留。
///
/// 这样重复套用不同模板不会互相覆盖，也不会把用户改过的标题/备注打回模板值。
public enum AccountTemplateFill {
    /// 把模板套用到当前草稿上。
    public static func apply(
        _ template: AccountTemplate,
        to draft: AccountTemplateFillDraft
    ) -> AccountTemplateFillOutcome {
        var filled = 0

        var title = draft.title
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !template.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = template.title.trimmingCharacters(in: .whitespacesAndNewlines)
            filled += 1
        }

        let existingURLs = LoginEntryURLRules.normalizedURLs(draft.urls)
        let mergedURLs = LoginEntryURLRules.normalizedURLs(existingURLs + template.defaultURLs)
        if mergedURLs != existingURLs {
            filled += 1
        }

        var notes = draft.notes
        if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !template.defaultNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes = template.defaultNotes
            filled += 1
        }

        let existingLabels = Set(
            draft.customFieldLabels.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        )
        let fieldsToAdd = template.defaultCustomFields.filter {
            !existingLabels.contains($0.trimmedLabel.lowercased())
        }

        return AccountTemplateFillOutcome(
            title: title,
            urls: mergedURLs,
            username: draft.username,
            notes: notes,
            customFieldsToAdd: fieldsToAdd,
            usernamePlaceholder: template.usernamePlaceholder,
            requiresTOTP: template.requiresTOTP,
            filledFieldCount: filled
        )
    }
}

// MARK: - JSON 导入/导出

/// 模板导入选项。
public struct AccountTemplateImportOptions: Sendable, Equatable {
    /// 当前保险库里已有的自定义模板 ID；用来识别冲突。
    public var existingTemplateIDs: Set<String>
    /// 冲突时是否覆盖已有模板（false 表示跳过并报告冲突）。
    public var overwriteExisting: Bool

    public init(existingTemplateIDs: Set<String> = [], overwriteExisting: Bool = false) {
        self.existingTemplateIDs = existingTemplateIDs
        self.overwriteExisting = overwriteExisting
    }
}

/// 模板导入结果：可导入列表 + 逐条问题 + 计数。
public struct AccountTemplateImportSummary: Sendable, Equatable {
    /// 文件声明的版本；识别不出文件格式时为 nil。
    public let formatVersion: Int?
    /// 通过校验、可以写入的模板（已归一化、已换掉内置 ID、已去重）。
    public let templates: [AccountTemplate]
    /// 逐条校验问题（文件级问题的 `sourceIndex` 为 nil）。
    public let issues: [VaultImportIssue]
    /// 文件里声明的模板条数。
    public let sourceTemplateCount: Int
    /// 被跳过（校验失败或冲突）的条数。
    public let skippedTemplateCount: Int
    /// 因为 ID 冲突被跳过的条数。
    public let conflictCount: Int
    /// 文件导出时间（如果带了）。
    public let exportedAt: Date?

    public var canImport: Bool { !templates.isEmpty }
    public var isEmptyFile: Bool { sourceTemplateCount == 0 && formatVersion == nil }
}

/// 模板 JSON 编解码：`{"format":"monica-account-templates","schemaVersion":1,...}`。
///
/// 与 #37 的保险库导入导出共用 `VaultImportIssue`/`VaultImportIssueCode`，
/// 保证两个入口的错误展示风格一致。
public enum AccountTemplateCodec {
    public static let formatIdentifier = "monica-account-templates"
    public static let schemaVersion = 1
    /// 模板文件本来就不含密码，10 MB 已经足够宽裕。
    public static let maximumFileSizeBytes = 10 * 1024 * 1024

    // MARK: 导出

    /// 导出自定义模板（内置模板是代码常量，不需要也不应该导出）。
    public static func export(templates: [AccountTemplate], now: Date = Date()) throws -> Data {
        let object: [String: Any] = [
            "format": formatIdentifier,
            "schemaVersion": schemaVersion,
            "exportedAt": ISO8601DateFormatter().string(from: now),
            "templates": templates.map { $0.exportObject() }
        ]
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// 导出文件名，和 #37 的 `Monica-Vault-yyyyMMdd-HHmmss.json` 同风格。
    public static func suggestedFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Monica-Account-Templates-\(formatter.string(from: now)).json"
    }

    // MARK: 导入预览

    /// 解析并逐条校验模板文件；不触碰本地保险库。
    ///
    /// 文件级问题（格式不对、版本过新、文件过大）会让 `templates` 为空；
    /// 单条问题只会跳过该条，其余模板照常可导入。
    public static func preview(
        data: Data,
        options: AccountTemplateImportOptions = AccountTemplateImportOptions(),
        now: Date = Date()
    ) -> AccountTemplateImportSummary {
        var issues: [VaultImportIssue] = []

        guard data.count <= maximumFileSizeBytes else {
            issues.append(
                VaultImportIssue(
                    code: .fileTooLarge,
                    message: "文件超过 \(maximumFileSizeBytes / 1024 / 1024) MB，无法导入模板。"
                )
            )
            return AccountTemplateImportSummary(
                formatVersion: nil,
                templates: [],
                issues: issues,
                sourceTemplateCount: 0,
                skippedTemplateCount: 0,
                conflictCount: 0,
                exportedAt: nil
            )
        }

        guard !data.isEmpty else {
            issues.append(VaultImportIssue(code: .malformedJSON, message: "文件是空的，没有可导入的模板。"))
            return AccountTemplateImportSummary(
                formatVersion: nil,
                templates: [],
                issues: issues,
                sourceTemplateCount: 0,
                skippedTemplateCount: 0,
                conflictCount: 0,
                exportedAt: nil
            )
        }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            issues.append(
                VaultImportIssue(
                    code: .malformedJSON,
                    message: "不是有效的模板 JSON 文件。请选择由「导出模板」生成的 .json 文件。"
                )
            )
            return AccountTemplateImportSummary(
                formatVersion: nil,
                templates: [],
                issues: issues,
                sourceTemplateCount: 0,
                skippedTemplateCount: 0,
                conflictCount: 0,
                exportedAt: nil
            )
        }

        let declaredFormat = root["format"] as? String
        if let declaredFormat, declaredFormat != formatIdentifier {
            issues.append(
                VaultImportIssue(
                    code: .unrecognizedFormat,
                    field: "format",
                    message: "这不是 Monica 的模板文件（format=\(declaredFormat)）。"
                )
            )
            return AccountTemplateImportSummary(
                formatVersion: nil,
                templates: [],
                issues: issues,
                sourceTemplateCount: 0,
                skippedTemplateCount: 0,
                conflictCount: 0,
                exportedAt: nil
            )
        }

        let version = (root["schemaVersion"] as? Int) ?? (root["schemaVersion"] as? NSNumber)?.intValue
        if let version, version > schemaVersion {
            issues.append(
                VaultImportIssue(
                    code: .unsupportedVersion,
                    field: "schemaVersion",
                    message: "模板文件版本 \(version) 比当前 App 支持的 \(schemaVersion) 更新，请先升级 App。"
                )
            )
            return AccountTemplateImportSummary(
                formatVersion: version,
                templates: [],
                issues: issues,
                sourceTemplateCount: 0,
                skippedTemplateCount: 0,
                conflictCount: 0,
                exportedAt: nil
            )
        }

        let exportedAt = (root["exportedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let rawTemplates = root["templates"] as? [Any] ?? []

        guard !rawTemplates.isEmpty else {
            issues.append(VaultImportIssue(code: .missingRequiredField, field: "templates", message: "文件里没有任何模板。"))
            return AccountTemplateImportSummary(
                formatVersion: version ?? schemaVersion,
                templates: [],
                issues: issues,
                sourceTemplateCount: 0,
                skippedTemplateCount: 0,
                conflictCount: 0,
                exportedAt: exportedAt
            )
        }

        var templates: [AccountTemplate] = []
        var skipped = 0
        var conflicts = 0
        var fileIDs = Set<String>()

        for (index, raw) in rawTemplates.enumerated() {
            guard let dict = raw as? [String: Any] else {
                issues.append(
                    VaultImportIssue(
                        sourceIndex: index,
                        code: .invalidField,
                        message: "第 \(index + 1) 条模板不是对象，已跳过。"
                    )
                )
                skipped += 1
                continue
            }
            var parsed: AccountTemplate?
            do {
                parsed = try template(from: dict, index: index)
            } catch let error as AccountTemplateImportFieldError {
                issues.append(error.issue(sourceIndex: index))
                skipped += 1
                continue
            } catch {
                issues.append(
                    VaultImportIssue(
                        sourceIndex: index,
                        code: .invalidField,
                        message: "第 \(index + 1) 条模板无法解析，已跳过。"
                    )
                )
                skipped += 1
                continue
            }
            guard var template = parsed else {
                skipped += 1
                continue
            }

            // 内置 ID 一律换新：内置模板是代码常量，导入一份副本没有意义，
            // 还会和目录里的同名模板打架。
            if AccountTemplateCatalog.isBuiltinTemplateID(template.templateID) || template.isBuiltin {
                template.templateID = UUID().uuidString
                template.isBuiltin = false
                issues.append(
                    VaultImportIssue(
                        sourceIndex: index,
                        code: .skippedValue,
                        field: "templateID",
                        message: "第 \(index + 1) 条模板来自内置模板，已作为自定义副本导入。"
                    )
                )
            }
            template.isBuiltin = false

            // 文件内部重复：保留第一条，后面的跳过。
            if fileIDs.contains(template.templateID) {
                issues.append(
                    VaultImportIssue(
                        sourceIndex: index,
                        code: .duplicateItem,
                        field: "templateID",
                        message: "第 \(index + 1) 条模板与文件里的另一条 ID 重复，已跳过。"
                    )
                )
                skipped += 1
                conflicts += 1
                continue
            }
            // 与保险库里已有模板冲突：默认跳过，用户勾选「覆盖」时才替换。
            if options.existingTemplateIDs.contains(template.templateID), !options.overwriteExisting {
                issues.append(
                    VaultImportIssue(
                        sourceIndex: index,
                        code: .duplicateItem,
                        field: "templateID",
                        message: "第 \(index + 1) 条模板「\(template.displayTitle)」与已有模板冲突，已跳过。勾选覆盖可以替换。"
                    )
                )
                skipped += 1
                conflicts += 1
                continue
            }

            fileIDs.insert(template.templateID)
            template.sortOrder = templates.count
            template.updatedAt = now
            templates.append(template)
        }

        return AccountTemplateImportSummary(
            formatVersion: version ?? schemaVersion,
            templates: templates,
            issues: issues,
            sourceTemplateCount: rawTemplates.count,
            skippedTemplateCount: skipped,
            conflictCount: conflicts,
            exportedAt: exportedAt
        )
    }

    /// 单条模板的字段错误。
    struct AccountTemplateImportFieldError: Error {
        let code: VaultImportIssueCode
        let field: String?
        let message: String

        func issue(sourceIndex: Int) -> VaultImportIssue {
            VaultImportIssue(sourceIndex: sourceIndex, code: code, field: field, message: message)
        }
    }

    /// 解析并归一化一条模板；返回 nil 表示已作为「跳过」报告。
    static func template(from dict: [String: Any], index: Int) throws -> AccountTemplate? {
        let rawTitle = ((dict["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else {
            throw AccountTemplateImportFieldError(
                code: .missingRequiredField,
                field: "title",
                message: "第 \(index + 1) 条模板缺少标题，已跳过。"
            )
        }
        guard let itemKind = UnifiedVaultItemKind(rawValue: (dict["itemKind"] as? String) ?? "login") else {
            throw AccountTemplateImportFieldError(
                code: .unsupportedItemKind,
                field: "itemKind",
                message: "第 \(index + 1) 条模板的类型不受支持，已跳过。"
            )
        }
        let rawFields = dict["defaultCustomFields"] as? [Any] ?? []
        var fields: [AccountTemplateCustomField] = []
        for rawField in rawFields {
            guard let fieldDict = rawField as? [String: Any] else { continue }
            let label = ((fieldDict["label"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            let kind = VaultCustomFieldKind(storageValue: fieldDict["kind"] as? String)
            guard !kind.isProtected else {
                throw AccountTemplateImportFieldError(
                    code: .invalidField,
                    field: "defaultCustomFields",
                    message: "第 \(index + 1) 条模板「\(rawTitle)」包含隐藏文本字段，可能携带密钥，已跳过。"
                )
            }
            fields.append(
                AccountTemplateCustomField(
                    label: label,
                    kind: kind,
                    defaultValue: (fieldDict["defaultValue"] as? String) ?? ""
                )
            )
        }

        var template = AccountTemplate(
            templateID: ((dict["templateID"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            title: rawTitle,
            itemKind: itemKind,
            defaultURLs: (dict["defaultURLs"] as? [String]) ?? [],
            usernamePlaceholder: (dict["usernamePlaceholder"] as? String) ?? "",
            defaultNotes: (dict["defaultNotes"] as? String) ?? "",
            defaultCustomFields: fields,
            requiresTOTP: (dict["requiresTOTP"] as? Bool) ?? false
        )
        if template.templateID.isEmpty {
            template.templateID = UUID().uuidString
        }

        do {
            return try template.normalized()
        } catch let error as AccountTemplateError {
            throw AccountTemplateImportFieldError(
                code: code(for: error),
                field: field(for: error),
                message: "第 \(index + 1) 条模板「\(rawTitle)」被跳过：\(error.localizedDescription)"
            )
        }
    }

    static func code(for error: AccountTemplateError) -> VaultImportIssueCode {
        switch error {
        case .emptyTitle, .emptyCustomFieldLabel:
            return .missingRequiredField
        case .protectedCustomFieldUnsupported:
            return .invalidField
        case .tooManyURLs, .tooManyCustomFields, .titleTooLong, .notesTooLong,
             .usernamePlaceholderTooLong, .customFieldLabelTooLong:
            return .skippedValue
        default:
            return .invalidField
        }
    }

    static func field(for error: AccountTemplateError) -> String? {
        switch error {
        case .emptyTitle, .titleTooLong:
            return "title"
        case .tooManyURLs, .invalidURL:
            return "defaultURLs"
        case .tooManyCustomFields, .emptyCustomFieldLabel, .customFieldLabelTooLong, .protectedCustomFieldUnsupported:
            return "defaultCustomFields"
        case .notesTooLong:
            return "defaultNotes"
        case .usernamePlaceholderTooLong:
            return "usernamePlaceholder"
        default:
            return nil
        }
    }
}

// MARK: - 引擎侧表方法（默认空实现，避免打断所有测试替身）

public extension LocalVaultEngine {
    /// 列出锚点工程里保存的模板记录。
    func listAccountTemplates(
        in handle: LocalVaultHandle,
        anchorProjectID: String
    ) throws -> [AccountTemplate] {
        []
    }

    /// 写入（新增或覆盖）一条模板记录。
    func saveAccountTemplate(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        template: AccountTemplate
    ) throws {}

    /// 删除一条模板记录（写墓碑，可在回收站恢复）。
    func deleteAccountTemplate(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        templateID: String
    ) throws {}
}
