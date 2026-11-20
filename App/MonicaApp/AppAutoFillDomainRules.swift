import Foundation
import MonicaCore
import MonicaSecurity
import SwiftUI

/// 把 Keychain 的不透明 payload 适配成 `MonicaCore` 的规则存储协议。
///
/// 规则内容（域名、备注）只存在于 Keychain 与内存里；适配层不记录任何日志。
struct KeychainDomainRuleRepository: AutoFillDomainRuleStoring {
    private let store: KeychainAutoFillDomainRuleStore

    init(store: KeychainAutoFillDomainRuleStore = KeychainAutoFillDomainRuleStore()) {
        self.store = store
    }

    func loadRuleSet(vaultID: String) async throws -> AutoFillDomainRuleSet? {
        guard let payload = try await store.loadPayload(vaultID: vaultID) else {
            return nil
        }
        return try AutoFillDomainRuleCodec.decode(payload)
    }

    func saveRuleSet(_ ruleSet: AutoFillDomainRuleSet, vaultID: String) async throws {
        let payload = try AutoFillDomainRuleCodec.encode(ruleSet)
        try await store.savePayload(payload, vaultID: vaultID)
    }

    func deleteRuleSet(vaultID: String) async throws {
        try await store.deletePayload(vaultID: vaultID)
    }
}

/// 自动填充域名规则（#40）的 App 侧控制器。
///
/// 规则存在 Keychain（`KeychainAutoFillDomainRuleStore`），只在保险库解锁后加载；
/// 锁库时清空内存副本，避免离开锁定状态后仍能被读出。
@MainActor
final class AutoFillDomainRuleController: ObservableObject {
    @Published private(set) var ruleSet: AutoFillDomainRuleSet = .empty
    @Published private(set) var isLoaded = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false

    @Published var draftPattern = ""
    @Published var draftKind: AutoFillDomainRuleKind = .block
    @Published var draftIncludesSubdomains = true
    @Published var draftNote = ""

    private let store: any AutoFillDomainRuleStoring
    private var vaultID: String?

    init(store: any AutoFillDomainRuleStoring = KeychainDomainRuleRepository()) {
        self.store = store
    }

    var isVaultUnlocked: Bool { vaultID != nil }

    var blockedRules: [AutoFillDomainRule] { ruleSet.blockedRules }
    var allowedRules: [AutoFillDomainRule] { ruleSet.allowedRules }

    /// 保险库解锁后调用；重复调用同一个 vaultID 是幂等的。
    func attach(vaultID: String) async {
        let trimmed = vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            detach()
            return
        }
        guard self.vaultID != trimmed else { return }
        self.vaultID = trimmed
        await reload()
    }

    /// 锁库时调用：丢掉内存副本，不删除 Keychain 里的规则。
    func detach() {
        vaultID = nil
        ruleSet = .empty
        isLoaded = false
        statusMessage = nil
        statusIsError = false
        draftPattern = ""
        draftNote = ""
    }

    func reload() async {
        guard let vaultID else {
            isLoaded = false
            return
        }
        do {
            ruleSet = try await store.loadRuleSet(vaultID: vaultID) ?? .empty
            isLoaded = true
            setStatus(nil, isError: false)
        } catch {
            ruleSet = .empty
            isLoaded = true
            setStatus(String(localized: "读取自动填充规则失败，请重新解锁后重试。"), isError: true)
        }
    }

    /// 校验并追加草稿规则；失败时把原因写进 `statusMessage`。
    @discardableResult
    func addDraftRule() async -> Bool {
        guard isVaultUnlocked else {
            setStatus(String(localized: "请先解锁保险库。"), isError: true)
            return false
        }
        let rawPattern = draftPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPattern.isEmpty else {
            setStatus(String(localized: "请输入域名，例如 example.com。"), isError: true)
            return false
        }
        guard let rule = AutoFillDomainRule(
            rawPattern: rawPattern,
            kind: draftKind,
            includesSubdomains: draftIncludesSubdomains,
            note: draftNote
        ) else {
            setStatus(String(localized: "无法识别的域名。请只填写域名本身，不要带空格、协议或路径。"), isError: true)
            return false
        }
        guard ruleSet.add(rule) else {
            setStatus(String(localized: "该域名已有相同类型的规则。"), isError: true)
            return false
        }
        guard await persist() else {
            ruleSet.remove(id: rule.id)
            return false
        }
        draftPattern = ""
        draftNote = ""
        setStatus(
            rule.kind == .block
                ? String(localized: "已屏蔽该域名的自动填充。")
                : String(localized: "已为该域名添加例外规则。"),
            isError: false
        )
        return true
    }

    func remove(_ rule: AutoFillDomainRule) async {
        guard ruleSet.remove(id: rule.id) else { return }
        guard await persist() else {
            ruleSet.add(rule)
            return
        }
        setStatus(String(localized: "已删除规则。"), isError: false)
    }

    /// 判断一条凭据的 service identifier 是否应被隐藏（供 App 发布身份时使用）。
    func hidesServiceIdentifier(_ identifier: String) -> Bool {
        ruleSet.hidesServiceIdentifier(identifier)
    }

    @discardableResult
    private func persist() async -> Bool {
        guard let vaultID else {
            setStatus(String(localized: "请先解锁保险库。"), isError: true)
            return false
        }
        do {
            try await store.saveRuleSet(ruleSet, vaultID: vaultID)
            return true
        } catch {
            setStatus(String(localized: "保存自动填充规则失败，请稍后重试。"), isError: true)
            return false
        }
    }

    private func setStatus(_ message: String?, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}

/// 设置 → 自动填充 → 域名规则。
struct AutoFillDomainRulesSettingsView: View {
    @ObservedObject var controller: AutoFillDomainRuleController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !controller.isVaultUnlocked {
                AndroidParityInfoRow(
                    title: String(localized: "状态"),
                    value: String(localized: "解锁保险库后可管理")
                )
            }

            addRuleCard

            if let statusMessage = controller.statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(controller.statusIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ruleList(
                title: String(localized: "屏蔽的域名"),
                rules: controller.blockedRules,
                emptyText: String(localized: "还没有屏蔽任何域名。")
            )
            ruleList(
                title: String(localized: "例外域名"),
                rules: controller.allowedRules,
                emptyText: String(localized: "还没有例外域名。")
            )

            Text("这些规则只影响 Monica 自己提供的自动填充候选和凭据标识。系统设置里其它密码管理器、以及你在系统面板中手动选择的其它来源都不受影响。规则保存在本机 Keychain，不写入日志，也不进入备份。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addRuleCard: some View {
        AndroidParityCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("添加规则")
                    .font(.headline)

                TextField(String(localized: "域名，例如 example.com"), text: $controller.draftPattern)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)

                Picker(String(localized: "类型"), selection: $controller.draftKind) {
                    Text("屏蔽自动填充").tag(AutoFillDomainRuleKind.block)
                    Text("例外放行").tag(AutoFillDomainRuleKind.allow)
                }
                .pickerStyle(.segmented)

                Toggle(String(localized: "同时匹配子域名"), isOn: $controller.draftIncludesSubdomains)

                TextField(String(localized: "备注（可选）"), text: $controller.draftNote)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await controller.addDraftRule() }
                } label: {
                    Label("添加规则", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.isVaultUnlocked)
            }
        }
    }

    private func ruleList(title: String, rules: [AutoFillDomainRule], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if rules.isEmpty {
                Text(emptyText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rules) { rule in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.pattern)
                                .font(.body.monospaced())
                            Text(subtitle(for: rule))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button(role: .destructive) {
                            Task { await controller.remove(rule) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(String(localized: "删除规则"))
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func subtitle(for rule: AutoFillDomainRule) -> String {
        var parts: [String] = []
        parts.append(rule.includesSubdomains ? String(localized: "含子域名") : String(localized: "仅此域名"))
        let note = rule.note
        if !note.isEmpty {
            parts.append(note)
        }
        return parts.joined(separator: " · ")
    }
}
