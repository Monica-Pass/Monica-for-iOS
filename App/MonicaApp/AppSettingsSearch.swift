import SwiftUI

// MARK: - 设置页 section 目录

/// 设置页上可被搜索命中的 section 锚点。
///
/// `rawValue` 同时是滚动锚点与高亮状态使用的稳定 id；`titleKey` 必须和
/// `AndroidParitySection(title:)` 在界面上展示的标题逐字一致。
/// `AppSettingsSearchTests` 会扫描设置页源码核对这份目录：新增 section
/// 却忘记登记索引、或改了标题却忘记同步这里时，测试会直接失败。
enum AppSettingsSection: String, CaseIterable, Hashable, Identifiable, Sendable {
    case developer
    case appearance
    case language
    case localVault
    case application
    case interfaceDensity
    case layout
    case plus
    case masterPassword
    case securityQuestions
    case autoFill
    case autoFillExtension
    case autoFillDomainRules
    case keyboardInput
    case steamImport
    case securityCenter
    case sensitivePrivacy
    case timeline
    case permissions
    case migration
    case formatImportExport
    case oneDrive
    case bitwarden
    case bitwardenSend
    case webDAV
    case nfcDiagnostics
    case lanSync
    case iCloudSync
    case cloudVault
    case haptics
    case dataManagement
    case about

    var id: String { rawValue }

    /// 与界面上的 section 标题完全一致的本地化键。
    var titleKey: String {
        switch self {
        case .developer: "开发者"
        case .appearance: "主题与图标"
        case .language: "语言"
        case .localVault: "本地保险库"
        case .application: "应用"
        case .interfaceDensity: "界面密度"
        case .layout: "布局"
        case .plus: "Monica Plus"
        case .masterPassword: "主密码"
        case .securityQuestions: "密保问题"
        case .autoFill: "自动填充"
        case .autoFillExtension: "启用 Monica 作为密码管理器"
        case .autoFillDomainRules: "自动填充域名规则"
        case .keyboardInput: "键盘与输入法"
        case .steamImport: "Steam 导入"
        case .securityCenter: "安全中心"
        case .sensitivePrivacy: "敏感隐私"
        case .timeline: "Timeline"
        case .permissions: "权限管理"
        case .migration: "迁移"
        case .formatImportExport: "格式导入导出"
        case .oneDrive: "OneDrive"
        case .bitwarden: "Bitwarden"
        case .bitwardenSend: "接收 Bitwarden Send"
        case .webDAV: "WebDAV"
        case .nfcDiagnostics: "NFC 银行卡诊断"
        case .lanSync: "局域网同步"
        case .iCloudSync: "iCloud 同步"
        case .cloudVault: "云端保险库"
        case .haptics: "触感反馈"
        case .dataManagement: "数据管理"
        case .about: "关于"
        }
    }

    /// 当前语言下的 section 标题。
    var title: String {
        String(localized: String.LocalizationValue(titleKey))
    }

    /// 结果行的路径面包屑，例如「设置 › 自动填充」。
    var breadcrumb: String {
        String(localized: "设置") + " › " + title
    }
}

// MARK: - 索引项

/// 一条可被搜索的设置项。`id` 稳定，不随语言或界面顺序变化。
struct AppSettingsSearchItem: Identifiable, Equatable, Sendable {
    let id: String
    let titleKey: String
    let section: AppSettingsSection
    /// 同义词 / 英文 / 拼音，仅参与匹配，不展示给用户。
    let keywords: [String]
    /// 锁定态下只保留标题，不再暴露关键词（主密码、密钥、凭据相关）。
    let isSensitive: Bool
    /// 仅在开发者模式解锁后才存在的 section。
    let requiresDeveloperMode: Bool

    init(
        id: String,
        titleKey: String,
        section: AppSettingsSection,
        keywords: [String],
        isSensitive: Bool = false,
        requiresDeveloperMode: Bool = false
    ) {
        self.id = id
        self.titleKey = titleKey
        self.section = section
        self.keywords = keywords
        self.isSensitive = isSensitive
        self.requiresDeveloperMode = requiresDeveloperMode
    }

    /// 结果行的标题，跟随 App 语言。
    var title: String {
        String(localized: String.LocalizationValue(titleKey))
    }

    /// 点击结果后滚动到的位置。
    var scrollAnchor: AppSettingsSection { section }

    /// 结果行的路径面包屑。
    var breadcrumb: String { section.breadcrumb }

    /// 保险库锁定时，敏感项只保留标题（关键词清空，避免从锁屏设置页泄露线索）。
    func redactingKeywordsForLockedVault() -> AppSettingsSearchItem {
        AppSettingsSearchItem(
            id: id,
            titleKey: titleKey,
            section: section,
            keywords: [],
            isSensitive: true,
            requiresDeveloperMode: requiresDeveloperMode
        )
    }
}

// MARK: - 匹配与排序

enum AppSettingsSearchMatchTier: Int, Comparable, Sendable {
    /// 所有 query 词都命中标题。
    case title = 0
    /// 每个 query 词至少命中标题或关键词，且至少一个词只命中关键词。
    case keyword = 1
    /// 有 query 词只能通过 section 路径命中。
    case path = 2

    static func < (lhs: AppSettingsSearchMatchTier, rhs: AppSettingsSearchMatchTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct AppSettingsSearchResult: Identifiable, Equatable, Sendable {
    let item: AppSettingsSearchItem
    let tier: AppSettingsSearchMatchTier
    let titleHitCount: Int
    let keywordHitCount: Int

    var id: String { item.id }
    var title: String { item.title }
    var breadcrumb: String { item.breadcrumb }
    var scrollAnchor: AppSettingsSection { item.scrollAnchor }
}

/// 纯本地的设置搜索：NFKC 归一化 + 忽略大小写 + 多词 AND，无网络、无第三方库。
enum AppSettingsSearch {
    /// NFKC 归一化（全角转半角等）后统一小写。
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
    }

    /// 按空白切词，每个词都必须命中（AND）。
    static func tokens(in query: String) -> [String] {
        normalize(query)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    static func match(item: AppSettingsSearchItem, tokens: [String]) -> AppSettingsSearchResult? {
        guard !tokens.isEmpty else { return nil }

        let title = normalize(item.title)
        let keywords = normalize(item.keywords.joined(separator: " "))
        let path = normalize(item.breadcrumb)

        var titleHits = 0
        var keywordHits = 0
        for token in tokens {
            if title.contains(token) {
                titleHits += 1
            } else if keywords.contains(token) {
                keywordHits += 1
            } else if !path.contains(token) {
                return nil
            }
        }

        let tier: AppSettingsSearchMatchTier
        if titleHits == tokens.count {
            tier = .title
        } else if titleHits + keywordHits == tokens.count {
            tier = .keyword
        } else {
            tier = .path
        }

        return AppSettingsSearchResult(
            item: item,
            tier: tier,
            titleHitCount: titleHits,
            keywordHitCount: keywordHits
        )
    }
}

// MARK: - 索引

enum AppSettingsSearchIndex {
    /// 全部索引项。顺序只用于同分排序（靠前的 section 优先），不代表界面顺序依赖。
    static let all: [AppSettingsSearchItem] = [
        // 开发者（仅开发者模式解锁后可见）
        AppSettingsSearchItem(
            id: "developer.diagnostics",
            titleKey: "诊断日志",
            section: .developer,
            keywords: ["开发者", "developer", "开发者模式", "developer mode", "诊断", "diagnostics", "日志", "log", "脱敏", "redacted"],
            requiresDeveloperMode: true
        ),

        // 主题与图标
        AppSettingsSearchItem(
            id: "appearance.color-scheme",
            titleKey: "颜色模式",
            section: .appearance,
            keywords: ["外观", "appearance", "颜色", "color", "深色", "dark", "浅色", "light", "主题", "theme", "深浅色"]
        ),
        AppSettingsSearchItem(
            id: "appearance.theme-preset",
            titleKey: "主题预设",
            section: .appearance,
            keywords: ["主题", "theme", "预设", "preset", "配色", "palette", "强调色", "accent"]
        ),
        AppSettingsSearchItem(
            id: "appearance.custom-accent",
            titleKey: "自定义强调色",
            section: .appearance,
            keywords: ["强调色", "accent", "自定义", "custom", "颜色", "color", "主题", "theme"]
        ),
        AppSettingsSearchItem(
            id: "appearance.password-icons",
            titleKey: "密码列表图标",
            section: .appearance,
            keywords: ["图标", "icon", "密码列表", "password list", "条目图标", "item icon"]
        ),
        AppSettingsSearchItem(
            id: "appearance.app-icon",
            titleKey: "App 图标",
            section: .appearance,
            keywords: ["图标", "icon", "app icon", "备用图标", "alternate icon", "桌面图标", "恢复默认图标"]
        ),

        // 语言
        AppSettingsSearchItem(
            id: "language.app-language",
            titleKey: "应用语言",
            section: .language,
            keywords: ["语言", "language", "应用语言", "english", "英文", "中文", "简体中文", "localization", "本地化", "yuyan"]
        ),

        // 本地保险库
        AppSettingsSearchItem(
            id: "local-vault.registry",
            titleKey: "本地保险库",
            section: .localVault,
            keywords: ["保险库", "vault", "本地", "local", "列表", "registry", "切换", "switch", "baoxiangu"]
        ),

        // 应用
        AppSettingsSearchItem(
            id: "application.system-requirements",
            titleKey: "系统要求",
            section: .application,
            keywords: ["系统要求", "system requirements", "ios", "版本要求", "version"]
        ),
        AppSettingsSearchItem(
            id: "application.backup",
            titleKey: "备份",
            section: .application,
            keywords: ["备份", "backup", "首次备份", "first backup", "恢复", "restore", "beifen"]
        ),
        AppSettingsSearchItem(
            id: "application.key-policy",
            titleKey: "密钥策略",
            section: .application,
            keywords: ["密钥策略", "key policy", "密钥", "key", "生物识别", "biometric", "安全基线"],
            isSensitive: true
        ),
        AppSettingsSearchItem(
            id: "application.version",
            titleKey: "应用版本",
            section: .application,
            keywords: ["应用版本", "version", "版本号", "build", "开发者模式", "developer mode"]
        ),
        AppSettingsSearchItem(
            id: "application.vault-keychain",
            titleKey: "保险库钥匙串",
            section: .application,
            keywords: ["钥匙串", "keychain", "保险库", "vault", "状态", "status"],
            isSensitive: true
        ),
        AppSettingsSearchItem(
            id: "application.biometric-unlock",
            titleKey: "生物识别解锁",
            section: .application,
            keywords: ["生物识别", "biometric", "face id", "touch id", "指纹", "面容", "解锁", "unlock"]
        ),
        AppSettingsSearchItem(
            id: "application.auto-lock",
            titleKey: "自动锁定",
            section: .application,
            keywords: ["自动锁定", "auto lock", "auto-lock", "超时", "timeout", "锁定", "lock"]
        ),
        AppSettingsSearchItem(
            id: "application.card-density",
            titleKey: "卡片密度",
            section: .application,
            keywords: ["卡片密度", "card density", "卡片", "card", "密度", "density", "列表"]
        ),
        AppSettingsSearchItem(
            id: "application.login-username",
            titleKey: "账号字段",
            section: .application,
            keywords: ["账号字段", "username", "字段", "field", "登录名", "login"]
        ),
        AppSettingsSearchItem(
            id: "application.login-url",
            titleKey: "网址字段",
            section: .application,
            keywords: ["网址字段", "url", "字段", "field", "网站", "website"]
        ),
        AppSettingsSearchItem(
            id: "application.tab-labels",
            titleKey: "底部导航文字",
            section: .application,
            keywords: ["底部导航", "tab bar", "导航", "navigation", "文字", "label"]
        ),
        AppSettingsSearchItem(
            id: "application.keychain-unlock",
            titleKey: "使用钥匙串解锁",
            section: .application,
            keywords: ["钥匙串", "keychain", "解锁", "unlock"],
            isSensitive: true
        ),
        AppSettingsSearchItem(
            id: "application.quick-setup",
            titleKey: "快速设置",
            section: .application,
            keywords: ["快速设置", "quick setup", "引导", "wizard", "首次使用"]
        ),
        AppSettingsSearchItem(
            id: "application.extensions",
            titleKey: "扩展功能",
            section: .application,
            keywords: ["扩展功能", "extensions", "小组件", "widget", "快捷指令", "shortcuts"]
        ),
        AppSettingsSearchItem(
            id: "application.account-templates",
            titleKey: "常用账号模板",
            section: .application,
            keywords: ["账号模板", "template", "模板", "常用账号"]
        ),

        // 界面密度
        AppSettingsSearchItem(
            id: "interface-density.picker",
            titleKey: "界面密度",
            section: .interfaceDensity,
            keywords: ["界面密度", "interface density", "密度", "density", "间距", "spacing", "行高", "字号", "紧凑", "宽松"]
        ),
        AppSettingsSearchItem(
            id: "interface-density.restore-default",
            titleKey: "恢复默认界面密度",
            section: .interfaceDensity,
            keywords: ["恢复默认", "reset", "密度", "density"]
        ),

        // 布局
        AppSettingsSearchItem(
            id: "layout.modules",
            titleKey: "密码页模块",
            section: .layout,
            keywords: ["布局", "layout", "模块", "module", "顺序", "order", "显隐", "隐藏", "hide", "密码页"]
        ),
        AppSettingsSearchItem(
            id: "layout.restore-default",
            titleKey: "恢复默认布局",
            section: .layout,
            keywords: ["恢复默认", "reset", "布局", "layout"]
        ),

        // Monica Plus
        AppSettingsSearchItem(
            id: "plus.supporter",
            titleKey: "Monica Plus",
            section: .plus,
            keywords: ["plus", "monica plus", "支持者", "supporter", "赞助", "donation", "捐赠", "支持作者", "support", "购买"]
        ),
        AppSettingsSearchItem(
            id: "plus.restore-purchase",
            titleKey: "恢复购买",
            section: .plus,
            keywords: ["恢复购买", "restore purchase", "购买", "purchase", "支持者", "supporter"]
        ),

        // 主密码（锁定态只保留标题）
        AppSettingsSearchItem(
            id: "master-password.change",
            titleKey: "主密码",
            section: .masterPassword,
            keywords: ["主密码", "master password", "masterpassword", "zhumima", "修改主密码", "更新主密码", "change password", "密钥", "包裹"],
            isSensitive: true
        ),

        // 密保问题（锁定态只保留标题）
        AppSettingsSearchItem(
            id: "security-questions.manage",
            titleKey: "密保问题",
            section: .securityQuestions,
            keywords: ["密保问题", "密保", "security questions", "recovery questions", "找回密码", "账号恢复", "mibao"],
            isSensitive: true
        ),

        // 自动填充
        AppSettingsSearchItem(
            id: "auto-fill.index",
            titleKey: "更新自动填充索引",
            section: .autoFill,
            keywords: ["自动填充", "autofill", "auto fill", "填充", "索引", "index", "更新", "refresh", "zidongtianchong", "tianchong"]
        ),
        AppSettingsSearchItem(
            id: "auto-fill.blocked-fields",
            titleKey: "忽略字段",
            section: .autoFill,
            keywords: ["自动填充", "autofill", "忽略", "ignore", "阻止", "block", "字段", "field"]
        ),
        AppSettingsSearchItem(
            id: "auto-fill.blocked-save-targets",
            titleKey: "忽略保存目标",
            section: .autoFill,
            keywords: ["自动填充", "autofill", "忽略", "ignore", "阻止", "block", "保存目标", "save target"]
        ),
        AppSettingsSearchItem(
            id: "auto-fill.enablement",
            titleKey: "启用 Monica 作为密码管理器",
            section: .autoFillExtension,
            keywords: ["自动填充", "autofill", "zidongtianchong", "启用", "enable", "密码管理器", "mimaguanliqi", "password manager", "系统设置", "settings"]
        ),
        AppSettingsSearchItem(
            id: "ui.haptics",
            titleKey: "触感反馈",
            section: .haptics,
            keywords: ["触感", "震动", "振动", "haptic", "haptics", "feedback", "zhendong"]
        ),
        AppSettingsSearchItem(
            id: "data.management",
            titleKey: "数据管理",
            section: .dataManagement,
            keywords: ["数据", "清理", "data", "management", "按类型", "shuju", "qingli"]
        ),
        AppSettingsSearchItem(
            id: "auto-fill.domain-rules",
            titleKey: "自动填充域名规则",
            section: .autoFillDomainRules,
            keywords: ["域名", "domain", "规则", "rule", "自动填充", "autofill", "阻止", "block", "网址", "url"]
        ),

        // 键盘与输入法
        AppSettingsSearchItem(
            id: "keyboard.limitations",
            titleKey: "键盘与输入法",
            section: .keyboardInput,
            keywords: ["键盘", "keyboard", "输入法", "ime", "限制", "limitation"]
        ),

        // Steam 导入
        AppSettingsSearchItem(
            id: "steam.import",
            titleKey: "Steam 导入",
            section: .steamImport,
            keywords: ["steam", "mafile", "导入", "import", "令牌", "authenticator", "游戏", "game"]
        ),

        // 安全中心
        AppSettingsSearchItem(
            id: "security-center.dashboard",
            titleKey: "安全分析仪表盘",
            section: .securityCenter,
            keywords: ["安全", "security", "仪表盘", "dashboard", "安全分析", "泄露", "breach", "弱密码", "weak password", "重复密码", "reused"]
        ),
        AppSettingsSearchItem(
            id: "security-center.repair-suggestions",
            titleKey: "安全修复建议",
            section: .securityCenter,
            keywords: ["安全", "security", "修复", "repair", "建议", "suggestion", "泄露", "breach"]
        ),
        AppSettingsSearchItem(
            id: "security-center.recent-operations",
            titleKey: "最近操作",
            section: .securityCenter,
            keywords: ["安全", "security", "操作", "operation", "记录", "timeline", "审计", "audit"]
        ),
        AppSettingsSearchItem(
            id: "security-center.duplicate-logins",
            titleKey: "重复登录项",
            section: .securityCenter,
            keywords: ["重复", "duplicate", "合并", "merge", "登录项", "login", "安全", "security"]
        ),

        // 敏感隐私
        AppSettingsSearchItem(
            id: "sensitive-privacy.clipboard",
            titleKey: "复制后自动清除剪贴板",
            section: .sensitivePrivacy,
            keywords: ["敏感", "sensitive", "隐私", "privacy", "剪贴板", "clipboard", "自动清除", "clear", "复制", "copy"]
        ),
        AppSettingsSearchItem(
            id: "sensitive-privacy.masking",
            titleKey: "始终遮蔽敏感预览",
            section: .sensitivePrivacy,
            keywords: ["敏感", "sensitive", "遮蔽", "mask", "预览", "preview", "隐私", "privacy", "掩码"]
        ),

        // Timeline
        AppSettingsSearchItem(
            id: "timeline.kind-filter",
            titleKey: "类型",
            section: .timeline,
            keywords: ["timeline", "时间线", "记录", "history", "历史", "类型", "kind", "筛选", "filter"]
        ),
        AppSettingsSearchItem(
            id: "timeline.action-filter",
            titleKey: "动作",
            section: .timeline,
            keywords: ["timeline", "时间线", "记录", "history", "动作", "action", "筛选", "filter"]
        ),

        // 权限管理
        AppSettingsSearchItem(
            id: "permissions.status",
            titleKey: "权限管理",
            section: .permissions,
            keywords: ["权限", "permission", "通知", "notification", "相机", "camera", "麦克风", "microphone", "照片", "photos"]
        ),

        // 迁移
        AppSettingsSearchItem(
            id: "migration.csv",
            titleKey: "CSV",
            section: .migration,
            keywords: ["csv", "导入", "import", "导出", "export", "迁移", "migrate", "数据管理", "data management"]
        ),
        AppSettingsSearchItem(
            id: "migration.keepass",
            titleKey: "KeePass / KDBX",
            section: .migration,
            keywords: ["keepass", "kdbx", "kdb", "导入", "import", "数据库", "database", "迁移", "migrate", "数据管理", "data management"],
            isSensitive: true
        ),
        AppSettingsSearchItem(
            id: "migration.keepass-credentials",
            titleKey: "KeePass 凭据",
            section: .migration,
            keywords: ["keepass", "kdbx", "密钥文件", "key file", "密码", "password", "凭据", "credential"],
            isSensitive: true
        ),
        AppSettingsSearchItem(
            id: "migration.mobile-backup",
            titleKey: "移动端备份",
            section: .migration,
            keywords: ["备份", "backup", "mobile backup", "导入", "import", "导出", "export", "加密备份", "beifen", "数据管理", "data management"]
        ),
        AppSettingsSearchItem(
            id: "migration.credential-exchange",
            titleKey: "凭据交换（CXF）",
            section: .migration,
            keywords: ["凭据交换", "credential exchange", "cxf", "通行密钥", "passkey", "迁移", "导出", "数据管理", "data management"]
        ),

        // 格式导入导出
        AppSettingsSearchItem(
            id: "formats.import-export",
            titleKey: "格式导入导出",
            section: .formatImportExport,
            keywords: ["格式", "format", "导入", "import", "导出", "export", "1password", "json", "数据管理", "data management"]
        ),

        // OneDrive
        AppSettingsSearchItem(
            id: "one-drive.account",
            titleKey: "OneDrive 账号",
            section: .oneDrive,
            keywords: ["onedrive", "微软", "microsoft", "账号", "account", "登录", "login"]
        ),
        AppSettingsSearchItem(
            id: "one-drive.backup",
            titleKey: "备份目录",
            section: .oneDrive,
            keywords: ["onedrive", "备份", "backup", "目录", "folder", "上传", "upload", "beifen"]
        ),
        AppSettingsSearchItem(
            id: "one-drive.restore",
            titleKey: "预览并恢复",
            section: .oneDrive,
            keywords: ["onedrive", "恢复", "restore", "下载", "download", "预览", "preview"]
        ),

        // Bitwarden
        AppSettingsSearchItem(
            id: "bitwarden.sync",
            titleKey: "Bitwarden 同步",
            section: .bitwarden,
            keywords: ["bitwarden", "同步", "sync", "导入", "import", "预览", "preview"]
        ),
        AppSettingsSearchItem(
            id: "bitwarden.send",
            titleKey: "接收 Bitwarden Send",
            section: .bitwardenSend,
            keywords: ["bitwarden send", "send", "接收", "receive", "链接", "link", "过期", "expires"]
        ),

        // WebDAV
        AppSettingsSearchItem(
            id: "web-dav.backup",
            titleKey: "WebDAV 备份",
            section: .webDAV,
            keywords: ["webdav", "备份", "backup", "服务器", "server", "上传", "upload", "后台备份"]
        ),
        AppSettingsSearchItem(
            id: "web-dav.restore",
            titleKey: "恢复备份",
            section: .webDAV,
            keywords: ["webdav", "恢复", "restore", "下载", "download", "备份列表"]
        ),

        // NFC 银行卡诊断
        AppSettingsSearchItem(
            id: "nfc.card-diagnostics",
            titleKey: "NFC 银行卡诊断",
            section: .nfcDiagnostics,
            keywords: ["nfc", "银行卡", "bank card", "诊断", "diagnostics", "贴卡", "技术验证"]
        ),

        // 局域网同步
        AppSettingsSearchItem(
            id: "lan-sync.pairing",
            titleKey: "局域网同步",
            section: .lanSync,
            keywords: ["局域网", "lan", "同步", "sync", "配对", "pair", "验证码", "wi-fi", "热点"]
        ),

        // iCloud 同步
        AppSettingsSearchItem(
            id: "icloud-sync.toggle",
            titleKey: "iCloud 同步",
            section: .iCloudSync,
            keywords: ["icloud", "同步", "sync", "云端", "cloud", "私人数据库", "private database"]
        ),
        AppSettingsSearchItem(
            id: "icloud-sync.check",
            titleKey: "检查 iCloud 账号",
            section: .iCloudSync,
            keywords: ["icloud", "检查", "check", "账号", "account", "云端变更", "change"]
        ),

        // 云端保险库
        AppSettingsSearchItem(
            id: "cloud-vault.push-pull",
            titleKey: "云端保险库",
            section: .cloudVault,
            keywords: ["云端", "cloud", "保险库", "vault", "上传", "push", "拉取", "pull", "下载", "版本冲突", "conflict"]
        ),

        // 关于
        AppSettingsSearchItem(
            id: "about.update",
            titleKey: "检查更新",
            section: .about,
            keywords: ["关于", "about", "更新", "update", "版本", "version", "检查更新", "开源", "open source", "许可", "license"]
        )
    ]

    /// 按当前锁定 / 开发者模式状态过滤后的索引项。
    static func items(isVaultUnlocked: Bool, isDeveloperModeUnlocked: Bool) -> [AppSettingsSearchItem] {
        all.compactMap { item in
            if item.requiresDeveloperMode && !isDeveloperModeUnlocked {
                return nil
            }
            if item.isSensitive && !isVaultUnlocked {
                return item.redactingKeywordsForLockedVault()
            }
            return item
        }
    }

    /// 实时搜索结果：标题命中 > 关键词命中 > 路径命中；同层保持索引顺序。
    static func results(
        for query: String,
        isVaultUnlocked: Bool,
        isDeveloperModeUnlocked: Bool
    ) -> [AppSettingsSearchResult] {
        let tokens = AppSettingsSearch.tokens(in: query)
        guard !tokens.isEmpty else { return [] }

        let candidates = items(
            isVaultUnlocked: isVaultUnlocked,
            isDeveloperModeUnlocked: isDeveloperModeUnlocked
        )

        return candidates
            .enumerated()
            .compactMap { index, item -> (Int, AppSettingsSearchResult)? in
                guard let result = AppSettingsSearch.match(item: item, tokens: tokens) else {
                    return nil
                }
                return (index, result)
            }
            .sorted { lhs, rhs in
                if lhs.1.tier != rhs.1.tier {
                    return lhs.1.tier < rhs.1.tier
                }
                if lhs.1.titleHitCount != rhs.1.titleHitCount {
                    return lhs.1.titleHitCount > rhs.1.titleHitCount
                }
                if lhs.1.keywordHitCount != rhs.1.keywordHitCount {
                    return lhs.1.keywordHitCount > rhs.1.keywordHitCount
                }
                return lhs.0 < rhs.0
            }
            .map(\.1)
    }
}

// MARK: - 搜索结果界面

struct AppSettingsSearchResultsView: View {
    let query: String
    let isVaultUnlocked: Bool
    let isDeveloperModeUnlocked: Bool
    let onSelect: (AppSettingsSection) -> Void

    private var results: [AppSettingsSearchResult] {
        AppSettingsSearchIndex.results(
            for: query,
            isVaultUnlocked: isVaultUnlocked,
            isDeveloperModeUnlocked: isDeveloperModeUnlocked
        )
    }

    var body: some View {
        AndroidParityScreen {
            AndroidParitySection(title: String(localized: "搜索结果")) {
                if results.isEmpty {
                    emptyState
                } else {
                    AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                        ForEach(results) { result in
                            resultRow(result)
                            if result.id != results.last?.id {
                                AndroidParityDivider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                Text("没有找到匹配的设置")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                Text("试试「自动填充」「备份」「语言」等关键词，或检查是否有多余的空格。")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private func resultRow(_ result: AppSettingsSearchResult) -> some View {
        Button {
            onSelect(result.scrollAnchor)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(AndroidParityTypography.smallIcon(weight: .semibold))
                    .foregroundStyle(AndroidParityPalette.primary)
                    .frame(width: 28, height: 28)
                    .background(AndroidParityPalette.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(result.breadcrumb)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.turn.down.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-search-result-\(result.id)")
    }
}

// MARK: - section 锚点

extension View {
    /// 给设置 section 挂上搜索定位锚点，并在跳转后短暂显示高亮背景。
    ///
    /// 高亮背景使用负 padding 画在布局之外，不改变既有 section 的间距与顺序。
    func settingsSearchAnchor(_ section: AppSettingsSection, highlighted: Bool) -> some View {
        id(section)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AndroidParityPalette.primary.opacity(highlighted ? 0.16 : 0))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -6)
                    .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.25), value: highlighted)
    }
}
