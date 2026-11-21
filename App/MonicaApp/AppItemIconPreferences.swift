//
//  AppItemIconPreferences.swift
//  Monica
//
//  Issue #149：条目图标全局体系（App 侧）。
//  - 偏好存储：独立的 `monica.itemIconPreferences` UserDefaults key，纯本地、不随库迁移。
//  - 渲染：列表行内的固定尺寸头像槽位（关闭时同尺寸透明占位，行高不跳动）。
//  - 设置区块：「条目图标」总开关 + 分页面开关 + 未匹配策略 + 来源优先级。
//
//  纯模型与解析规则在 MonicaCore 的 `ItemIconPreferences.swift`；本文件只负责
//  持久化、条目 → 解析请求的映射，以及 SwiftUI 渲染。
//

import Foundation
import MonicaCore
import MonicaStorage
import SwiftUI

// MARK: - 存储

protocol AppItemIconPreferenceStore: Sendable {
    func loadPreferences() -> ItemIconPreferences
    func savePreferences(_ preferences: ItemIconPreferences)
}

/// 图标偏好写入 `monica.itemIconPreferences`（JSON）。
///
/// 与保险库数据完全分离：备份 / 恢复 / 跨设备迁移都不会带上这份设置，
/// 恢复备份后回到默认值（总开关开、分页面全开、首字母、内置目录 > SF Symbol > 首字母）。
final class UserDefaultsAppItemIconPreferenceStore: AppItemIconPreferenceStore, @unchecked Sendable {
    static let storageKey = "monica.itemIconPreferences"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadPreferences() -> ItemIconPreferences {
        guard let data = userDefaults.data(forKey: Self.storageKey) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(ItemIconPreferences.self, from: data)
        } catch {
            // 配置损坏或来自未知 schema：安全回退默认值，保留原始数据不删除。
            NSLog(
                "Monica: item icon preferences could not be decoded (%@); using defaults.",
                String(describing: error)
            )
            return .default
        }
    }

    func savePreferences(_ preferences: ItemIconPreferences) {
        do {
            let data = try JSONEncoder().encode(preferences.normalized())
            userDefaults.set(data, forKey: Self.storageKey)
        } catch {
            NSLog(
                "Monica: item icon preferences could not be encoded (%@); keeping existing value.",
                String(describing: error)
            )
        }
    }
}

/// 测试与预览用的内存后端。
final class MemoryAppItemIconPreferenceStore: AppItemIconPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var preferences: ItemIconPreferences

    init(preferences: ItemIconPreferences = .default) {
        self.preferences = preferences.normalized()
    }

    func loadPreferences() -> ItemIconPreferences {
        lock.lock()
        defer { lock.unlock() }
        return preferences
    }

    func savePreferences(_ preferences: ItemIconPreferences) {
        lock.lock()
        self.preferences = preferences.normalized()
        lock.unlock()
    }
}

// MARK: - 条目 → 解析请求

extension ItemIconRequest {
    /// 密码页条目。
    static func login(_ entry: LocalLoginEntry) -> ItemIconRequest {
        ItemIconRequest(
            page: .password,
            kindID: "login",
            storedValue: entry.icon,
            title: entry.title,
            secondaryText: entry.username,
            domains: entry.effectiveURLs
        )
    }

    /// 验证码页条目。`iconName` 是页面独有列，空字符串表示「跟随默认」。
    static func totp(_ entry: LocalTotpEntry) -> ItemIconRequest {
        let explicitSymbol: String? = entry.iconName.isEmpty
            ? nil
            : TotpIconCatalog.systemName(for: entry.iconName)
        let issuerDomain: [String] = Self.isDomainLike(entry.issuer) ? [entry.issuer] : []
        return ItemIconRequest(
            page: .totp,
            kindID: "totp",
            explicitSymbol: explicitSymbol,
            title: entry.title,
            secondaryText: entry.issuer.isEmpty ? entry.accountName : entry.issuer,
            domains: issuerDomain
        )
    }

    /// 通行密钥页条目：域名取 relying party，服务商符号仅在 SF Symbol 白名单内才作为来源。
    static func passkey(_ entry: LocalPasskeyEntry, providerSymbol: String?) -> ItemIconRequest {
        ItemIconRequest(
            page: .passkey,
            kindID: "passkey",
            title: entry.title,
            secondaryText: entry.username,
            domains: [entry.relyingPartyID],
            symbolOverride: providerSymbol.flatMap {
                ItemIconCatalog.isKnownSymbol($0) ? $0 : nil
            }
        )
    }

    /// issuer 只有长得像域名时才参与内置目录匹配，避免把「银行」这类机构名当主机名。
    private static func isDomainLike(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains(".") else { return false }
        return !trimmed.contains(where: { $0.isWhitespace })
    }
}

// MARK: - 头像视图

/// 列表行里的条目图标槽位。
///
/// 永远是固定尺寸：关闭图标 / 未匹配隐藏时渲染透明占位，因此行高、前导留白、
/// 文本起始位置都保持不变，不会出现开关图标导致的列表跳动。
/// 不做任何图片解码（没有 favicon、没有网络请求）：符号用 `Image(systemName:)`，
/// 首字母用 `Text`。
struct AppItemIconAvatarView: View {
    let avatar: ItemIconAvatar
    var size: CGFloat = ItemIconSlotMetrics.size
    var cornerRadius: CGFloat = ItemIconSlotMetrics.cornerRadius
    var fill: Color = AndroidParityPalette.primaryContainer
    var tint: Color = AndroidParityPalette.primary

    var body: some View {
        ZStack {
            if avatar.isPlaceholder {
                Color.clear
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                content
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(avatar.isPlaceholder)
    }

    @ViewBuilder
    private var content: some View {
        switch avatar {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(tint)
        case .initial(let text):
            Text(text)
                .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(2)
        case .placeholder:
            EmptyView()
        }
    }
}

// MARK: - 设置区块

/// 设置页「条目图标」区块：总开关、分页面开关、未匹配策略、来源优先级与预览。
struct AppItemIconSettingsView: View {
    let session: AppSessionModel

    private var preferences: ItemIconPreferences {
        session.itemIconPreferences
    }

    var body: some View {
        AndroidParitySection(title: String(localized: "条目图标")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                Toggle(isOn: enabledBinding) {
                    Text("显示条目图标")
                        .font(.headline.weight(.heavy))
                }
                Text("关闭后列表保留同样大小的空位，行高与留白不会跳动。")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)

                AndroidParityDivider()

                Text("分页面")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                pageToggle("密码页图标", page: .password)
                pageToggle("验证码页图标", page: .totp)
                pageToggle("通行密钥页图标", page: .passkey)

                AndroidParityDivider()

                Picker("未匹配时", selection: policyBinding) {
                    ForEach(ItemIconUnmatchedPolicy.allCases) { policy in
                        Text(policyTitle(policy)).tag(policy)
                    }
                }
                .font(.headline.weight(.heavy))
                .disabled(!preferences.isEnabled)
                Text("所有来源都没有命中时如何显示：默认图标按条目类型取符号，首字母取标题 / 域名的第一个字，隐藏只留空位。")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)

                AndroidParityDivider()

                Text("来源优先级")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                Text("从上到下依次尝试；条目自己选择的图标始终优先，不会被调序覆盖。")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                ForEach(preferences.orderedSources, id: \.self) { source in
                    priorityRow(source)
                }

                AndroidParityDivider()

                Text("预览")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                previewRow
                Text("图标设置保存在本机偏好中（UserDefaults），不随备份文件迁移；恢复备份或换机后需要重新调整。")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)

                Button {
                    session.restoreDefaultItemIconPreferences()
                } label: {
                    Label(String(localized: "恢复默认图标设置"), systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                .disabled(preferences == .default)
            }
        }
    }

    // MARK: 子视图

    private func pageToggle(_ title: String, page: ItemIconPage) -> some View {
        Toggle(isOn: pageBinding(page)) {
            Text(title)
                .font(.subheadline.weight(.heavy))
        }
        .disabled(!preferences.isEnabled)
    }

    private func priorityRow(_ source: ItemIconSource) -> some View {
        HStack(spacing: 12) {
            Image(systemName: sourceSystemImage(source))
                .frame(width: 22)
                .foregroundStyle(AndroidParityPalette.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(sourceTitle(source))
                    .font(.subheadline.weight(.heavy))
                Text(sourceDetail(source))
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            Spacer()
            Button {
                moveSource(source, offset: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(preferences.isFirstSource(source))
            .accessibilityLabel(String(localized: "上移"))
            Button {
                moveSource(source, offset: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(preferences.isLastSource(source))
            .accessibilityLabel(String(localized: "下移"))
        }
        .padding(.vertical, 4)
    }

    private var previewRow: some View {
        HStack(spacing: 12) {
            previewAvatar(
                ItemIconRequest(
                    page: .password,
                    kindID: "login",
                    title: "GitHub",
                    domains: ["github.com"]
                )
            )
            previewAvatar(ItemIconRequest(page: .password, kindID: "login", title: "招商银行"))
            previewAvatar(ItemIconRequest(page: .totp, kindID: "totp", title: "Zeta"))
            previewAvatar(
                ItemIconRequest(
                    page: .passkey,
                    kindID: "passkey",
                    title: "Google",
                    domains: ["google.com"]
                )
            )
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func previewAvatar(_ request: ItemIconRequest) -> some View {
        let avatar = ItemIconAvatarResolver.avatar(for: request, preferences: preferences)
        return AppItemIconAvatarView(avatar: avatar, size: 36)
    }

    // MARK: 绑定

    private var enabledBinding: Binding<Bool> {
        Binding {
            preferences.isEnabled
        } set: { isEnabled in
            var updated = preferences
            updated.isEnabled = isEnabled
            session.updateItemIconPreferences(updated)
        }
    }

    private func pageBinding(_ page: ItemIconPage) -> Binding<Bool> {
        Binding {
            switch page {
            case .password: preferences.showsPasswordPageIcons
            case .totp: preferences.showsTotpPageIcons
            case .passkey: preferences.showsPasskeyPageIcons
            }
        } set: { isEnabled in
            var updated = preferences
            updated.setEnabled(isEnabled, for: page)
            session.updateItemIconPreferences(updated)
        }
    }

    private var policyBinding: Binding<ItemIconUnmatchedPolicy> {
        Binding {
            preferences.unmatchedPolicy
        } set: { policy in
            var updated = preferences
            updated.unmatchedPolicy = policy
            session.updateItemIconPreferences(updated)
        }
    }

    private func moveSource(_ source: ItemIconSource, offset: Int) {
        var updated = preferences
        updated.moveSource(source, by: offset)
        guard updated.sourcePriority != preferences.sourcePriority else { return }
        session.updateItemIconPreferences(updated)
    }

    // MARK: 文案

    private func policyTitle(_ policy: ItemIconUnmatchedPolicy) -> String {
        switch policy {
        case .defaultIcon: String(localized: "默认图标")
        case .firstLetter: String(localized: "首字母")
        case .hidden: String(localized: "隐藏")
        }
    }

    private func sourceTitle(_ source: ItemIconSource) -> String {
        switch source {
        case .catalog: String(localized: "内置目录")
        case .symbol: String(localized: "SF Symbol")
        case .firstLetter: String(localized: "首字母")
        }
    }

    private func sourceSystemImage(_ source: ItemIconSource) -> String {
        switch source {
        case .catalog: "square.grid.2x2.fill"
        case .symbol: "star.fill"
        case .firstLetter: "textformat"
        }
    }

    private func sourceDetail(_ source: ItemIconSource) -> String {
        switch source {
        case .catalog: String(localized: "按域名与标题关键词匹配内置目录，完全本地，不抓取网站图标。")
        case .symbol: String(localized: "条目里选择的系统符号，以及通行密钥的服务商符号。")
        case .firstLetter: String(localized: "兜底槽位，按上面的「未匹配时」策略渲染。")
        }
    }
}
