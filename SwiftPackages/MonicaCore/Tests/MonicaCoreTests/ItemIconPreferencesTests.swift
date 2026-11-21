import Foundation
import Testing
import MonicaCore

@Suite("条目图标偏好（#149）")
struct ItemIconPreferencesTests {
    @Test func defaultsMatchIssueSpec() {
        let preferences = ItemIconPreferences.default
        #expect(preferences.version == 1)
        #expect(preferences.isEnabled)
        #expect(preferences.showsPasswordPageIcons)
        #expect(preferences.showsTotpPageIcons)
        #expect(preferences.showsPasskeyPageIcons)
        #expect(preferences.unmatchedPolicy == .firstLetter)
        #expect(preferences.sourcePriority == [.catalog, .symbol, .firstLetter])
        #expect(preferences.orderedSources == [.catalog, .symbol, .firstLetter])
    }

    @Test func stableRawValuesStayPersistable() {
        #expect(ItemIconPage.allCases.map(\.rawValue) == ["password", "totp", "passkey"])
        #expect(ItemIconUnmatchedPolicy.allCases.map(\.rawValue) == ["default_icon", "first_letter", "hidden"])
        #expect(ItemIconSource.allCases.map(\.rawValue) == ["catalog", "symbol", "first_letter"])
        #expect(ItemIconSource.defaultPriority == [.catalog, .symbol, .firstLetter])
    }

    @Test func codableRoundTripPreservesEveryField() throws {
        var preferences = ItemIconPreferences.default
        preferences.isEnabled = false
        preferences.showsPasswordPageIcons = false
        preferences.showsTotpPageIcons = true
        preferences.showsPasskeyPageIcons = false
        preferences.unmatchedPolicy = .hidden
        preferences.sourcePriority = [.firstLetter, .catalog, .symbol]

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(ItemIconPreferences.self, from: data)
        #expect(decoded == preferences)
        #expect(decoded.unmatchedPolicy == .hidden)
        #expect(decoded.sourcePriority == [.firstLetter, .catalog, .symbol])
        // 总开关关闭时 isEnabled(for:) 是「最终是否显示」，因此全为 false；
        // 分页面开关自身的状态仍被完整保留，重新打开总开关后恢复。
        #expect(!decoded.isEnabled(for: .totp))
        #expect(decoded.showsTotpPageIcons)
        #expect(!decoded.showsPasswordPageIcons)
        var reopened = decoded
        reopened.isEnabled = true
        #expect(reopened.isEnabled(for: .totp))
        #expect(!reopened.isEnabled(for: .password))
    }

    @Test func decodingIsTolerantOfMissingAndUnknownFields() throws {
        let partial = Data(#"{"version":1,"unmatchedPolicy":"hidden"}"#.utf8)
        let decoded = try JSONDecoder().decode(ItemIconPreferences.self, from: partial)
        #expect(decoded.isEnabled)
        #expect(decoded.showsPasswordPageIcons)
        #expect(decoded.showsTotpPageIcons)
        #expect(decoded.showsPasskeyPageIcons)
        #expect(decoded.unmatchedPolicy == .hidden)
        #expect(decoded.sourcePriority == [.catalog, .symbol, .firstLetter])

        // 未知来源 ID 丢弃，剩余来源保留并把缺失项按默认顺序补到末尾。
        let unknownSource = Data(#"{"version":1,"sourcePriority":["first_letter","telepathy"]}"#.utf8)
        let tolerant = try JSONDecoder().decode(ItemIconPreferences.self, from: unknownSource)
        #expect(tolerant.sourcePriority == [.firstLetter, .catalog, .symbol])

        // 未知策略回退首字母。
        let unknownPolicy = Data(#"{"version":1,"unmatchedPolicy":"sparkles"}"#.utf8)
        let policy = try JSONDecoder().decode(ItemIconPreferences.self, from: unknownPolicy)
        #expect(policy.unmatchedPolicy == .firstLetter)

        // 重复来源只保留第一次出现的位置。
        let duplicated = Data(#"{"version":1,"sourcePriority":["symbol","symbol"]}"#.utf8)
        let deduplicated = try JSONDecoder().decode(ItemIconPreferences.self, from: duplicated)
        #expect(deduplicated.sourcePriority == [.symbol, .catalog, .firstLetter])
    }

    @Test func unknownVersionFallsBackToDefaults() throws {
        let future = Data(#"{"version":99,"isEnabled":false,"sourcePriority":["first_letter"]}"#.utf8)
        let decoded = try JSONDecoder().decode(ItemIconPreferences.self, from: future)
        #expect(decoded == ItemIconPreferences.default)
    }

    @Test func pageSwitchesComposeWithMasterSwitch() {
        var preferences = ItemIconPreferences.default
        preferences.setEnabled(false, for: .totp)
        #expect(!preferences.isEnabled(for: .totp))
        #expect(preferences.isEnabled(for: .password))
        #expect(preferences.isEnabled(for: .passkey))

        // 总开关关闭时，所有页面一律不显示图标。
        preferences.isEnabled = false
        for page in ItemIconPage.allCases {
            #expect(!preferences.isEnabled(for: page))
        }

        // 重新打开总开关，分页面开关保持各自状态。
        preferences.isEnabled = true
        #expect(!preferences.isEnabled(for: .totp))
        #expect(preferences.isEnabled(for: .password))

        preferences.setEnabled(true, for: .totp)
        #expect(preferences.isEnabled(for: .totp))
        #expect(preferences.showsTotpPageIcons)
    }

    @Test func movingSourcesKeepsACompletePermutation() {
        var preferences = ItemIconPreferences.default
        preferences.moveSource(.firstLetter, by: -2)
        #expect(preferences.sourcePriority == [.firstLetter, .symbol, .catalog])
        #expect(preferences.isFirstSource(.firstLetter))
        #expect(preferences.isLastSource(.catalog))

        // 边界移动不改变顺序，也不会丢来源。
        preferences.moveSource(.firstLetter, by: -1)
        #expect(preferences.sourcePriority == [.firstLetter, .symbol, .catalog])
        preferences.moveSource(.catalog, by: 1)
        #expect(preferences.sourcePriority == [.firstLetter, .symbol, .catalog])

        var damaged = preferences
        damaged.sourcePriority = [.symbol]
        damaged.normalize()
        #expect(damaged.orderedSources == [.symbol, .catalog, .firstLetter])
        #expect(Set(damaged.orderedSources) == Set(ItemIconSource.allCases))
    }
}

@Suite("条目图标解析：策略 × 优先级（#149）")
struct ItemIconAvatarResolverTests {
    /// 三个来源的全部 6 种排列。
    static let allOrders: [[ItemIconSource]] = [
        [.catalog, .symbol, .firstLetter],
        [.catalog, .firstLetter, .symbol],
        [.symbol, .catalog, .firstLetter],
        [.symbol, .firstLetter, .catalog],
        [.firstLetter, .catalog, .symbol],
        [.firstLetter, .symbol, .catalog]
    ]

    private static func preferences(
        order: [ItemIconSource] = ItemIconSource.defaultPriority,
        policy: ItemIconUnmatchedPolicy = .firstLetter,
        isEnabled: Bool = true,
        password: Bool = true,
        totp: Bool = true,
        passkey: Bool = true
    ) -> ItemIconPreferences {
        ItemIconPreferences(
            isEnabled: isEnabled,
            showsPasswordPageIcons: password,
            showsTotpPageIcons: totp,
            showsPasskeyPageIcons: passkey,
            unmatchedPolicy: policy,
            sourcePriority: order
        )
    }

    /// 既有内置目录匹配（github.com），又有 SF Symbol 自动来源的条目。
    private static let githubRequest = ItemIconRequest(
        page: .password,
        kindID: "login",
        title: "工作账号",
        secondaryText: "git@example.com",
        domains: ["https://github.com/login"],
        symbolOverride: "lock.fill"
    )

    /// 两个自动来源都没有命中的条目。
    private static let unmatchedRequest = ItemIconRequest(
        page: .password,
        kindID: "login",
        title: "Zeta",
        secondaryText: "",
        domains: []
    )

    private static let devSymbol = ItemIconCatalog.entry(id: "dev")?.symbolName

    // MARK: 开关

    @Test func masterSwitchOffAlwaysRendersAPlaceholderSlot() {
        let preferences = Self.preferences(isEnabled: false)
        for page in ItemIconPage.allCases {
            let request = ItemIconRequest(
                page: page,
                kindID: page.rawValue,
                storedValue: "sf:star.fill",
                title: "GitHub"
            )
            let avatar = ItemIconAvatarResolver.avatar(for: request, preferences: preferences)
            #expect(avatar == .placeholder)
            #expect(avatar.isPlaceholder)
            #expect(avatar.reservesIconSlot)
        }
    }

    @Test func pageSwitchesOnlyAffectTheirOwnPage() {
        let preferences = Self.preferences(password: false)
        let passwordAvatar = ItemIconAvatarResolver.avatar(
            for: Self.githubRequest,
            preferences: preferences
        )
        #expect(passwordAvatar == .placeholder)

        let totpAvatar = ItemIconAvatarResolver.avatar(
            for: ItemIconRequest(page: .totp, kindID: "totp", title: "GitHub"),
            preferences: preferences
        )
        #expect(totpAvatar.systemName == Self.devSymbol)

        let passkeyAvatar = ItemIconAvatarResolver.avatar(
            for: ItemIconRequest(page: .passkey, kindID: "passkey", title: "GitHub", domains: ["github.com"]),
            preferences: preferences
        )
        #expect(passkeyAvatar.systemName == Self.devSymbol)
    }

    // MARK: 优先级

    @Test func catalogMatchOutranksSymbolInTheDefaultOrder() {
        let avatar = ItemIconAvatarResolver.avatar(for: Self.githubRequest, preferences: .default)
        #expect(avatar.systemName == Self.devSymbol)
    }

    @Test func movingSymbolAboveCatalogChangesTheRenderedIcon() {
        let preferences = Self.preferences(order: [.symbol, .catalog, .firstLetter])
        let avatar = ItemIconAvatarResolver.avatar(for: Self.githubRequest, preferences: preferences)
        #expect(avatar.systemName == "lock.fill")
    }

    @Test func symbolBeatsCatalogOnlyWhileItIsOrderedFirst() {
        for order in Self.allOrders {
            let avatar = ItemIconAvatarResolver.avatar(
                for: Self.githubRequest,
                preferences: Self.preferences(order: order)
            )
            switch order.first {
            case .catalog:
                #expect(avatar.systemName == Self.devSymbol)
            case .symbol:
                #expect(avatar.systemName == "lock.fill")
            case .firstLetter:
                #expect(avatar == .initial("工"))
            case .none:
                Issue.record("优先级不能为空")
            }
        }
    }

    @Test func unmatchedPolicyAppliesAtTheFirstLetterSource() {
        // 首字母槽位排在最前：未匹配条目按策略渲染。
        let firstLetterFirst = Self.preferences(order: [.firstLetter, .catalog, .symbol])
        #expect(
            ItemIconAvatarResolver.avatar(for: Self.unmatchedRequest, preferences: firstLetterFirst)
                == .initial("Z")
        )

        var defaultIconPolicy = firstLetterFirst
        defaultIconPolicy.unmatchedPolicy = .defaultIcon
        #expect(
            ItemIconAvatarResolver.avatar(for: Self.unmatchedRequest, preferences: defaultIconPolicy).systemName
                == "key.fill"
        )

        var hiddenPolicy = firstLetterFirst
        hiddenPolicy.unmatchedPolicy = .hidden
        #expect(
            ItemIconAvatarResolver.avatar(for: Self.unmatchedRequest, preferences: hiddenPolicy)
                == .placeholder
        )

        // 自动来源排在策略之前时，先命中自动来源。
        let symbolFirst = Self.preferences(order: [.symbol, .firstLetter, .catalog])
        #expect(
            ItemIconAvatarResolver.avatar(
                for: ItemIconRequest(
                    page: .password,
                    kindID: "login",
                    title: "Zeta",
                    symbolOverride: "star.fill"
                ),
                preferences: symbolFirst
            ).systemName == "star.fill"
        )
    }

    @Test func everyPolicyWorksWithEveryOrder() {
        for order in Self.allOrders {
            for policy in ItemIconUnmatchedPolicy.allCases {
                let preferences = Self.preferences(order: order, policy: policy)
                let avatar = ItemIconAvatarResolver.avatar(for: Self.unmatchedRequest, preferences: preferences)
                // 没有自动来源命中，因此结果只取决于首字母槽位的策略。
                switch policy {
                case .firstLetter:
                    #expect(avatar == .initial("Z"), "order=\(order) policy=\(policy)")
                case .defaultIcon:
                    #expect(avatar.systemName == "key.fill", "order=\(order) policy=\(policy)")
                case .hidden:
                    #expect(avatar == .placeholder, "order=\(order) policy=\(policy)")
                }
                #expect(avatar.reservesIconSlot)
            }
        }
    }

    // MARK: 显式图标

    @Test func explicitCatalogIconAlwaysWinsRegardlessOfPriority() {
        for order in Self.allOrders {
            let request = ItemIconRequest(
                page: .password,
                kindID: "login",
                storedValue: "catalog:bank",
                title: "GitHub",
                domains: ["github.com"]
            )
            let avatar = ItemIconAvatarResolver.avatar(for: request, preferences: Self.preferences(order: order))
            #expect(avatar.systemName == "building.columns.fill", "order=\(order)")
        }
    }

    @Test func explicitSymbolWinsAndUnknownStoredValueFallsThroughToPolicy() {
        let storedSymbol = ItemIconRequest(
            page: .password,
            kindID: "login",
            storedValue: "sf:star.fill",
            title: "GitHub"
        )
        #expect(
            ItemIconAvatarResolver.avatar(for: storedSymbol, preferences: .default).systemName == "star.fill"
        )

        // 未知 catalog id：既不能渲染成 key.fill，也不能吞掉条目，走未匹配策略。
        let unknown = ItemIconRequest(
            page: .password,
            kindID: "login",
            storedValue: "catalog:does-not-exist",
            title: "Zeta"
        )
        #expect(ItemIconAvatarResolver.avatar(for: unknown, preferences: .default) == .initial("Z"))

        // 旧格式（Android slug）继续有效。
        let legacy = ItemIconRequest(
            page: .password,
            kindID: "login",
            storedValue: "github",
            title: "任意标题"
        )
        #expect(ItemIconAvatarResolver.avatar(for: legacy, preferences: .default).systemName == Self.devSymbol)
    }

    @Test func pageSpecificExplicitSymbolIsRenderedVerbatim() throws {
        let request = ItemIconRequest(
            page: .totp,
            kindID: "totp",
            explicitSymbol: "  globe ",
            title: "GitHub"
        )
        #expect(ItemIconAvatarResolver.avatar(for: request, preferences: .default).systemName == "globe")

        let blank = ItemIconRequest(page: .totp, kindID: "totp", explicitSymbol: "   ", title: "Zeta")
        #expect(ItemIconAvatarResolver.avatar(for: blank, preferences: .default) == .initial("Z"))
    }

    // MARK: 默认图标策略

    @Test func defaultIconPolicyUsesTheItemKindSymbol() {
        let preferences = Self.preferences(order: [.firstLetter, .catalog, .symbol], policy: .defaultIcon)
        let login = ItemIconRequest(page: .password, kindID: "login", title: "")
        let totp = ItemIconRequest(page: .totp, kindID: "totp", title: "")
        let unknownKind = ItemIconRequest(page: .passkey, kindID: "mystery", title: "")
        #expect(ItemIconAvatarResolver.avatar(for: login, preferences: preferences).systemName == "key.fill")
        #expect(ItemIconAvatarResolver.avatar(for: totp, preferences: preferences).systemName == "text.badge.key")
        #expect(ItemIconAvatarResolver.avatar(for: unknownKind, preferences: preferences).systemName == "key.fill")
    }

    // MARK: 首字母

    @Test func initialComesFromTitleThenSecondaryTextThenDomain() {
        func initial(title: String, secondary: String = "", domains: [String] = []) -> String {
            ItemIconAvatarResolver.initial(
                for: ItemIconRequest(
                    page: .password,
                    kindID: "login",
                    title: title,
                    secondaryText: secondary,
                    domains: domains
                )
            )
        }
        #expect(initial(title: "  github") == "G")
        #expect(initial(title: "工作账号") == "工")
        #expect(initial(title: "", secondary: "alice") == "A")
        #expect(initial(title: "", secondary: "", domains: ["https://github.com/login"]) == "G")
        #expect(initial(title: "", secondary: "", domains: ["x.com"]) == "X")
        #expect(initial(title: "", secondary: "") == "#")
    }

    // MARK: 内置目录匹配

    @Test func catalogMatchingIsLocalAndDeterministic() {
        func catalogID(title: String, domains: [String] = []) -> String? {
            ItemIconAvatarResolver.catalogEntry(
                for: ItemIconRequest(
                    page: .password,
                    kindID: "login",
                    title: title,
                    secondaryText: "",
                    domains: domains
                )
            )?.id
        }
        #expect(catalogID(title: "", domains: ["https://www.github.com/login?x=1"]) == "dev")
        #expect(catalogID(title: "", domains: ["github.io"]) == "dev")
        #expect(catalogID(title: "", domains: ["network.example.com"]) == nil)
        #expect(catalogID(title: "招商银行") == "bank")
        #expect(catalogID(title: "GitHub工作账号") == "dev")
        #expect(catalogID(title: "Network") == nil)
        #expect(catalogID(title: "Mailbox") == nil)
        #expect(catalogID(title: "Mail") == "mail")
        #expect(catalogID(title: "mail.qq.com 邮箱") == "mail")
        #expect(catalogID(title: "") == nil)
    }

    // MARK: 布局稳定

    @Test func everyAvatarReservesTheSameSlot() {
        let avatars: [ItemIconAvatar] = [
            .symbol("key.fill"),
            .initial("G"),
            .initial("#"),
            .placeholder
        ]
        for avatar in avatars {
            #expect(avatar.reservesIconSlot)
        }
        // 关闭图标前后的槽位尺寸完全一致：行高与留白不跳动。
        #expect(ItemIconSlotMetrics.slotWidth(isIconVisible: false) == ItemIconSlotMetrics.slotWidth(isIconVisible: true))
        #expect(ItemIconSlotMetrics.slotHeight(isIconVisible: false) == ItemIconSlotMetrics.slotHeight(isIconVisible: true))
        #expect(ItemIconSlotMetrics.size == 40)
        #expect(ItemIconSlotMetrics.passkeySize == 54)
        #expect(ItemIconSlotMetrics.cornerRadius == 10)

        // 占位头像不带任何文案，避免读屏重复播报。
        #expect(ItemIconAvatar.placeholder.systemName == nil)
        #expect(ItemIconAvatar.placeholder.initialText == nil)
        #expect(ItemIconAvatar.placeholder.isPlaceholder)
    }
}

@Suite("条目图标编解码回归（#149）")
struct ItemIconCodecRegressionTests {
    @Test func storageCodecIsUnchanged() {
        #expect(ItemIcon.catalog("bank").storageValue == "catalog:bank")
        #expect(ItemIcon.symbol("key.fill").storageValue == "sf:key.fill")
        #expect(ItemIcon(storageValue: "catalog: BANK ") == .catalog("bank"))
        #expect(ItemIcon(storageValue: "sf: key.fill ") == .symbol("key.fill"))
        #expect(ItemIcon(storageValue: "key.fill") == nil)
        #expect(ItemIcon(storageValue: "") == nil)
    }

    @Test func resolverUsesResolvedSystemNameForKnownValuesOnly() {
        #expect(
            ItemIconAvatarResolver.explicitSystemName(
                for: ItemIconRequest(page: .password, kindID: "login", storedValue: "catalog:bank")
            ) == "building.columns.fill"
        )
        #expect(
            ItemIconAvatarResolver.explicitSystemName(
                for: ItemIconRequest(page: .password, kindID: "login", storedValue: "catalog:sparkles")
            ) == nil
        )
        #expect(
            ItemIconAvatarResolver.explicitSystemName(
                for: ItemIconRequest(page: .password, kindID: "login", storedValue: "sf:not.a.real.symbol")
            ) == nil
        )
    }
}
