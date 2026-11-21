import Foundation
import MonicaCore
import MonicaStorage
import MonicaWidgetShared

// slice B: WidgetShortcuts 域，从 AppSessionModel.swift 逐字搬移。
extension AppSessionModel {
    func shortcutEntrySummaries(matching query: String) -> [AppShortcutEntrySummary] {
        guard vaultState == .unlocked else {
            return []
        }

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allShortcutEntrySummaries().filter { summary in
            guard !normalizedQuery.isEmpty else {
                return true
            }
            return summary.title.localizedCaseInsensitiveContains(normalizedQuery)
                || summary.subtitle.localizedCaseInsensitiveContains(normalizedQuery)
                || summary.searchableText.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    func shortcutSnapshot() -> AppShortcutSnapshot {
        guard vaultState == .unlocked else {
            return .locked
        }
        return AppShortcutSnapshot(
            vaultState: .unlocked,
            entries: allShortcutEntrySummaries().map(AppShortcutSnapshotEntry.init(summary:))
        )
    }

    func refreshShortcutSnapshotIfConfigured() throws {
        guard let shortcutSnapshotStore else {
            return
        }
        try shortcutSnapshotStore.saveSnapshot(shortcutSnapshot())
    }

    func widgetSnapshot(now: Date = Date()) -> AppWidgetSnapshot {
        // #155：进度条样式跟随设置写进快照，Widget 才会和 App 画成同一种样式。
        let progressStyle = MonicaWidgetTotpProgressStyle(snapshotValue: totpCardPreferences.style.snapshotValue)
        guard vaultState == .unlocked else {
            return AppWidgetSnapshot(
                vaultState: .locked,
                totalEntryCount: 0,
                totpItems: [],
                shortcutItems: [],
                totpProgressStyle: progressStyle
            )
        }

        let totpItems = totpEntries.prefix(3).map { entry in
            AppWidgetTotpItem(
                id: entry.id,
                title: shortcutTitle(entry.title),
                issuer: entry.issuer,
                accountName: entry.accountName,
                secondsRemaining: totpTimeRemaining(for: entry, at: now),
                // Widget 用它把剩余秒数换算成比例；缺失字段读回时按 30 秒兜底。
                period: Int(entry.period)
            )
        }
        return AppWidgetSnapshot(
            vaultState: .unlocked,
            totalEntryCount: activeVaultEntryCount,
            totpItems: Array(totpItems),
            shortcutItems: allShortcutEntrySummaries().prefix(4).map(MonicaWidgetShortcutItem.init(summary:)),
            totpProgressStyle: progressStyle
        )
    }

    func refreshWidgetSnapshotIfConfigured(now: Date = Date()) throws {
        guard let widgetSnapshotStore else {
            return
        }
        try widgetSnapshotStore.saveSnapshot(widgetSnapshot(now: now))
    }

    /// Rewrites both App Group snapshots (a privacy-safe projection of the vault) and,
    /// only when at least one write succeeded, asks WidgetKit to reload.
    ///
    /// The reload is requested through `MonicaWidgetReloadScheduling`, which coalesces
    /// bursts: creating/importing many entries produces one timeline reload instead of one
    /// per entry. `reloadImmediately` is reserved for lock and vault switches, where the
    /// widget must observe the now-empty projection without waiting for the coalescing
    /// window. A failure never changes the vault operation result; the (secret-free) error
    /// description is kept in `widgetSnapshotSyncError` for diagnostics.
    @discardableResult
    func publishWidgetSnapshots(now: Date = Date(), reloadImmediately: Bool = false) -> Bool {
        var didWriteSnapshot = false
        if let widgetSnapshotStore {
            do {
                try widgetSnapshotStore.saveSnapshot(widgetSnapshot(now: now))
                didWriteSnapshot = true
            } catch {
                widgetSnapshotSyncError = error.localizedDescription
            }
        }
        if let shortcutSnapshotStore {
            do {
                try shortcutSnapshotStore.saveSnapshot(shortcutSnapshot())
                didWriteSnapshot = true
            } catch {
                widgetSnapshotSyncError = error.localizedDescription
            }
        }
        guard didWriteSnapshot else {
            return false
        }
        widgetSnapshotSyncError = nil
        guard let widgetReloadScheduler else {
            return true
        }
        if reloadImmediately {
            widgetReloadScheduler.requestImmediateReload()
        } else {
            widgetReloadScheduler.requestReload()
        }
        return true
    }

    func openShortcutEntry(_ summary: AppShortcutEntrySummary) throws {
        recordUserActivity()
        guard shortcutEntryExists(summary) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        // issue #153：快捷指令已经指定了条目，启动自动聚焦不要抢走焦点。
        didReceiveLaunchNavigationTarget = true

        let destination = destination(forShortcutEntryKind: summary.kind)
        selectedTab = destination.tab
        if let passwordModule = destination.passwordModule {
            self.passwordModule = passwordModule
        }
        if let otherKind = destination.otherKind {
            passwordOtherKind = otherKind
        }
        if summary.kind == .steam {
            totpModule = .steam
        }
        presentedDetailRoute = VaultItemRoute(kind: summary.kind, entryID: summary.id)
    }

    func shortcutEntryExists(_ summary: AppShortcutEntrySummary) -> Bool {
        switch summary.kind {
        case .login:
            return loginEntries.contains { $0.id == summary.id }
        case .note:
            return noteEntries.contains { $0.id == summary.id }
        case .totp:
            return totpEntries.contains { $0.id == summary.id }
        case .card:
            return cardEntries.contains { $0.id == summary.id }
        case .identity:
            return identityEntries.contains { $0.id == summary.id }
        case .passkey:
            return passkeyEntries.contains { $0.id == summary.id }
        case .sshKey:
            return sshKeyEntries.contains { $0.id == summary.id }
        case .gpgKey:
            return gpgKeyEntries.contains { $0.id == summary.id }
        case .apiToken:
            return apiTokenEntries.contains { $0.id == summary.id }
        case .wifi:
            return wifiEntries.contains { $0.id == summary.id }
        case .sso:
            return ssoEntries.contains { $0.id == summary.id }
        case .barcode:
            return barcodeEntries.contains { $0.id == summary.id }
        case .send:
            return sendEntries.contains { $0.id == summary.id }
        case .steam:
            return steamEntries.contains { $0.id == summary.id }
        case .billingAddress:
            return billingAddressEntries.contains { $0.id == summary.id }
        case .paymentAccount:
            return paymentAccountEntries.contains { $0.id == summary.id }
        case .attachmentRef:
            return false
        }
    }

    @discardableResult
    func openShortcutURL(_ url: URL) -> Bool {
        guard url.scheme == "monica",
              url.host() == "shortcut" else {
            return false
        }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count == 2,
              let kind = UnifiedVaultItemKind(rawValue: pathComponents[0]) else {
            return false
        }
        let entryID = pathComponents[1]
        do {
            try openShortcutEntry(
                AppShortcutEntrySummary(
                    id: entryID,
                    kind: kind,
                    title: "",
                    subtitle: "",
                    searchableText: ""
                )
            )
            return true
        } catch {
            vaultOperationState = .failed(String(localized: "快捷入口已失效，请重新选择条目。"))
            return false
        }
    }

    /// 统一处理 `monica://` 深链：旧的条目快捷入口与控制中心页面入口共用同一条导航路径。
    @discardableResult
    func openDeepLinkURL(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "otpauth" {
            handleOtpAuthDeepLink(url)
            return true
        }
        if openShortcutURL(url) {
            return true
        }
        // issue #36：Monica Send 的本地分享凭据（monica://send/<id>#<code>）与 .send 文件导入。
        if handleMonicaSendURL(url) {
            return true
        }
        guard url.scheme == "monica",
              url.host() == "open" else {
            return false
        }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count == 1,
              let page = MonicaControlPage(rawValue: pathComponents[0]) else {
            vaultOperationState = .failed("快捷入口无效，请重新选择页面。")
            return false
        }
        handleControlPage(page)
        return true
    }

    /// 控制按钮与深链都会走这里；锁定态只记录页面，绝不提前读取或展示条目。
    func handleControlPage(_ page: MonicaControlPage) {
        // issue #153：控制中心导航可能落在密码页且不留详情路由，单独记一笔。
        didReceiveLaunchNavigationTarget = true
        pendingControlPage = page
        consumePendingControlPageIfUnlocked()
    }

    /// 由视图在 vaultState 变为解锁时调用，覆盖首次创建、打开和生物识别解锁等所有路径。
    func consumePendingControlPageIfUnlocked() {
        guard vaultState == .unlocked,
              let page = pendingControlPage else {
            return
        }
        pendingControlPage = nil
        applyControlPage(page)
    }

    /// 从 App Group 取走控制中心留下的页面；启动、回到前台或收到通知时调用。
    func consumePendingControlNavigationIfAvailable() {
        guard let url = MonicaControlNavigationStore.consume(from: controlNavigationDefaults) else {
            return
        }
        _ = openDeepLinkURL(url)
    }

    func applyControlPage(_ page: MonicaControlPage) {
        recordUserActivity()
        selectedTab = page.appTab
        if page == .passwords {
            passwordModule = .login
        }
        presentedDetailRoute = nil
    }

    func allShortcutEntrySummaries() -> [AppShortcutEntrySummary] {
        var summaries: [AppShortcutEntrySummary] = []
        // 归档条目不得出现在快捷指令与自动填充候选里。
        summaries += loginEntries.filter { !$0.isArchived }.map(shortcutSummary(for:))
        summaries += noteEntries.filter { !$0.isArchived }.map(shortcutSummary(for:))
        summaries += totpEntries.filter { !$0.isArchived }.map(shortcutSummary(for:))
        summaries += cardEntries.filter { !$0.isArchived }.map(shortcutSummary(for:))
        summaries += identityEntries.filter { !$0.isArchived }.map(shortcutSummary(for:))
        summaries += passkeyEntries.filter { !$0.isArchived }.map(shortcutSummary(for:))
        summaries += sshKeyEntries.filter { !$0.isArchived }.map(shortcutSummary(for:))
        summaries += apiTokenEntries.filter { !$0.isArchived }.map(shortcutSummary(for:))
        summaries += wifiEntries.filter { !$0.isArchived }.map(shortcutSummary(for:))
        summaries += ssoEntries.filter { !$0.isArchived }.map(shortcutSummary(for:))
        summaries += sendEntries.filter { !$0.isArchived }.map(shortcutSummary(for:))
        summaries += steamEntries.filter { !$0.isArchived }.map(shortcutSummary(for:))
        summaries += gpgKeyEntries.map(shortcutSummary(for:))
        summaries += barcodeEntries.map(shortcutSummary(for:))
        summaries += billingAddressEntries.map(shortcutSummary(for:))
        summaries += paymentAccountEntries.map(shortcutSummary(for:))
        return summaries
    }

    func shortcutSummary(for entry: LocalLoginEntry) -> AppShortcutEntrySummary {
        let host = normalizedLoginHost(from: entry.url)
        let subtitle = shortcutSubtitle([entry.username, host])
        return AppShortcutEntrySummary(
            id: entry.id,
            kind: .login,
            title: shortcutTitle(entry.title),
            subtitle: subtitle,
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.login.localizedDisplayName, entry.title, entry.username, host])
        )
    }

    func shortcutSummary(for entry: LocalNoteEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .note,
            title: shortcutTitle(entry.title),
            subtitle: UnifiedVaultItemKind.note.localizedDisplayName,
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.note.localizedDisplayName, entry.title])
        )
    }

    func shortcutSummary(for entry: LocalTotpEntry) -> AppShortcutEntrySummary {
        let subtitle = shortcutSubtitle([entry.accountName, entry.issuer])
        return AppShortcutEntrySummary(
            id: entry.id,
            kind: .totp,
            title: shortcutTitle(entry.title),
            subtitle: subtitle,
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.totp.localizedDisplayName, entry.title, entry.issuer, entry.accountName])
        )
    }

    func shortcutSummary(for entry: LocalCardEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .card,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.cardholderName, entry.issuer, entry.network]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.card.localizedDisplayName, entry.title, entry.cardholderName, entry.issuer, entry.network])
        )
    }

    func shortcutSummary(for entry: LocalIdentityEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .identity,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.fullName, entry.documentType, entry.issuer, entry.country]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.identity.localizedDisplayName, entry.title, entry.fullName, entry.documentType, entry.issuer, entry.country])
        )
    }

    func shortcutSummary(for entry: LocalPasskeyEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .passkey,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.username, entry.relyingPartyID]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.passkey.localizedDisplayName, entry.title, entry.username, entry.relyingPartyID])
        )
    }

    func shortcutSummary(for entry: LocalSshKeyEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .sshKey,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.username, entry.host]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.sshKey.localizedDisplayName, entry.title, entry.username, entry.host])
        )
    }

    func shortcutSummary(for entry: LocalGPGKeyEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .gpgKey,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.ownerEmail, entry.keyID]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.gpgKey.localizedDisplayName, entry.title, entry.ownerName, entry.ownerEmail, entry.keyID, entry.fingerprint])
        )
    }

    func shortcutSummary(for entry: LocalApiTokenEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .apiToken,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.accountName, entry.issuer, entry.expiresAt]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.apiToken.localizedDisplayName, entry.title, entry.accountName, entry.issuer, entry.expiresAt])
        )
    }

    func shortcutSummary(for entry: LocalWifiEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .wifi,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.ssid, entry.securityType]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.wifi.localizedDisplayName, entry.title, entry.ssid, entry.securityType])
        )
    }

    func shortcutSummary(for entry: LocalSSOEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .sso,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.displayProviderName, entry.accountName]),
            searchableText: shortcutSearchableText([
                UnifiedVaultItemKind.sso.localizedDisplayName,
                entry.title,
                entry.displayProviderName,
                entry.accountName,
                entry.issuer
            ])
        )
    }

    func shortcutSummary(for entry: LocalBarcodeEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .barcode,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.symbology.displayName, entry.label]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.barcode.localizedDisplayName, entry.title, entry.symbology.displayName, entry.label])
        )
    }

    func shortcutSummary(for entry: LocalSendEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .send,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.expiresAt, String(localized: "最多查看 \(entry.maxViews) 次")]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.send.localizedDisplayName, entry.title, entry.expiresAt])
        )
    }

    func shortcutSummary(for entry: LocalSteamEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .steam,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.accountName, entry.issuer]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.steam.localizedDisplayName, entry.title, entry.accountName, entry.steamID])
        )
    }

    func shortcutSummary(for entry: LocalBillingAddressEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .billingAddress,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.fullName, entry.addressSummary]),
            searchableText: shortcutSearchableText([
                UnifiedVaultItemKind.billingAddress.localizedDisplayName,
                entry.title,
                entry.fullName,
                entry.addressSummary
            ])
        )
    }

    func shortcutSummary(for entry: LocalPaymentAccountEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .paymentAccount,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.provider, entry.kind.displayName]),
            searchableText: shortcutSearchableText([
                UnifiedVaultItemKind.paymentAccount.localizedDisplayName,
                entry.title,
                entry.provider,
                entry.accountName,
                entry.currency
            ])
        )
    }

    func shortcutTitle(_ value: String) -> String {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "未命名") : title
    }

    func shortcutSubtitle(_ values: [String?]) -> String {
        let parts = values.compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return parts.isEmpty ? String(localized: "可打开") : parts.joined(separator: " / ")
    }

    func shortcutSearchableText(_ values: [String?]) -> String {
        values.compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        .joined(separator: " ")
    }

    func destination(forShortcutEntryKind kind: UnifiedVaultItemKind) -> VaultShortcutDestination {
        switch kind {
        case .login:
            return VaultShortcutDestination(tab: .passwords, passwordModule: .login, otherKind: nil)
        case .note:
            return VaultShortcutDestination(tab: .passwords, passwordModule: .note, otherKind: nil)
        case .passkey:
            return VaultShortcutDestination(tab: .passwords, passwordModule: .passkey, otherKind: nil)
        case .sshKey, .apiToken, .wifi, .gpgKey, .sso, .barcode, .send, .attachmentRef:
            return VaultShortcutDestination(tab: .passwords, passwordModule: .other, otherKind: kind)
        case .totp, .steam:
            return VaultShortcutDestination(tab: .totp, passwordModule: nil, otherKind: nil)
        case .card, .identity, .billingAddress, .paymentAccount:
            return VaultShortcutDestination(tab: .wallet, passwordModule: nil, otherKind: nil)
        }
    }
}
