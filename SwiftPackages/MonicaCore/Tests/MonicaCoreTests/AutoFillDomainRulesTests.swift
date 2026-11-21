import Foundation
import Testing

@testable import MonicaCore

@Suite("自动填充域名规则")
struct AutoFillDomainRulesTests {
    // MARK: - 规范化

    @Test("URL、端口、路径、协议都被规范化成同一个 host")
    func normalizationCollapsesURLCeremony() throws {
        let expected = "example.com"
        let inputs = [
            "example.com",
            "EXAMPLE.COM",
            " example.com ",
            "https://example.com",
            "https://example.com/login?next=%2F",
            "https://user:pass@example.com:8443/path",
            "example.com:8443",
            "example.com.",
            "https://example.com./"
        ]
        for input in inputs {
            let host = try #require(AutoFillDomainNormalizer.normalizeHost(input), "应当能解析 \(input)")
            #expect(host == expected, "\(input) → \(host)")
        }
    }

    @Test("IDN 的 Unicode 与 punycode 写法等价")
    func normalizationHandlesIDN() throws {
        let unicode = try #require(AutoFillDomainNormalizer.normalizeHost("bücher.de"))
        let punycode = try #require(AutoFillDomainNormalizer.normalizeHost("xn--bcher-kva.de"))
        #expect(unicode == punycode)
        #expect(unicode == "bücher.de")
    }

    @Test("明显非法的输入被拒绝而不是猜一个域名出来")
    func normalizationRejectsGarbage() {
        let invalid = [
            "",
            "   ",
            "exa mple.com",
            "example..com",
            "-bad.com",
            "bad-.com",
            "https://",
            String(repeating: "a", count: 64) + ".com"
        ]
        for input in invalid {
            #expect(AutoFillDomainNormalizer.normalizeHost(input) == nil, "不应接受 \(input)")
        }
    }

    @Test("通配前缀只影响子域名开关，不进入保存的 pattern")
    func wildcardPrefixIsStripped() throws {
        let parsed = try #require(AutoFillDomainNormalizer.parseRulePattern("*.Example.com"))
        #expect(parsed.pattern == "example.com")
        #expect(parsed.isSubdomainCapable)
    }

    @Test("IPv4 只做精确匹配，不匹配子域名")
    func ipAddressIsExactMatchOnly() throws {
        let parsed = try #require(AutoFillDomainNormalizer.parseRulePattern("192.168.1.10"))
        #expect(parsed.isIPAddress)
        #expect(!parsed.isSubdomainCapable)

        let rule = try #require(AutoFillDomainRule(rawPattern: "192.168.1.10", kind: .block, includesSubdomains: true))
        #expect(rule.includesSubdomains == false)
        #expect(rule.matches(normalizedHost: "192.168.1.10"))
        #expect(!rule.matches(normalizedHost: "10.168.1.10"))
    }

    @Test("单标签 host 不能匹配子域名")
    func singleLabelIsExactOnly() throws {
        let rule = try #require(AutoFillDomainRule(rawPattern: "localhost", kind: .block, includesSubdomains: true))
        #expect(rule.pattern == "localhost")
        #expect(!rule.includesSubdomains)
        #expect(rule.matches(normalizedHost: "localhost"))
        #expect(!rule.matches(normalizedHost: "api.localhost"))
    }

    // MARK: - 匹配

    @Test("子域名按标签边界匹配，notexample.com 不能命中 example.com")
    func subdomainMatchingRespectsLabelBoundary() throws {
        let rule = try #require(AutoFillDomainRule(rawPattern: "example.com", kind: .block))
        #expect(rule.matches(normalizedHost: "example.com"))
        #expect(rule.matches(normalizedHost: "login.example.com"))
        #expect(rule.matches(normalizedHost: "a.b.example.com"))
        #expect(!rule.matches(normalizedHost: "notexample.com"))
        #expect(!rule.matches(normalizedHost: "example.com.evil.test"))
    }

    @Test("关闭子域名后只匹配自身")
    func subdomainMatchingCanBeDisabled() throws {
        let rule = try #require(
            AutoFillDomainRule(rawPattern: "example.com", kind: .block, includesSubdomains: false)
        )
        #expect(rule.matches(normalizedHost: "example.com"))
        #expect(!rule.matches(normalizedHost: "login.example.com"))
    }

    // MARK: - 判定

    @Test("例外规则优先于屏蔽规则")
    func allowRuleWinsOverBlockRule() throws {
        var set = AutoFillDomainRuleSet.empty
        let block = try #require(AutoFillDomainRule(rawPattern: "example.com", kind: .block))
        let allow = try #require(AutoFillDomainRule(rawPattern: "login.example.com", kind: .allow))
        let addedBlock = set.add(block)
        let addedAllow = set.add(allow)
        #expect(addedBlock && addedAllow)

        #expect(set.decision(for: "login.example.com") == .allowed)
        #expect(set.decision(for: "https://admin.example.com/") .isBlocked)
        #expect(set.decision(for: "example.com").isBlocked)
    }

    @Test("命中屏蔽规则时返回规则 id 与 pattern，便于界面说明原因")
    func blockedDecisionCarriesRuleIdentity() throws {
        var set = AutoFillDomainRuleSet.empty
        let rule = try #require(AutoFillDomainRule(rawPattern: "bank.example", kind: .block))
        set.add(rule)

        guard case let .blocked(ruleID, pattern) = set.decision(for: "https://online.bank.example/login") else {
            Issue.record("应当命中屏蔽规则")
            return
        }
        #expect(ruleID == rule.id)
        #expect(pattern == "bank.example")
    }

    @Test("无法规范化的候选默认放行，避免误伤")
    func unparsableCandidateIsAllowed() {
        let set = AutoFillDomainRuleSet(rules: [])
        #expect(set.decision(for: "").isBlocked == false)
        #expect(set.decision(for: "exa mple.com").isBlocked == false)
    }

    @Test("凭据的 service identifier 既可以是 URL 也可以是裸域名")
    func hidesServiceIdentifierHandlesBothShapes() throws {
        var set = AutoFillDomainRuleSet.empty
        set.add(try #require(AutoFillDomainRule(rawPattern: "example.com", kind: .block)))
        #expect(set.hidesServiceIdentifier("https://example.com/login"))
        #expect(set.hidesServiceIdentifier("example.com"))
        #expect(!set.hidesServiceIdentifier("https://other.test"))
    }

    // MARK: - 集合操作

    @Test("同类型同 pattern 的重复规则不会重复追加")
    func addingDuplicateRuleIsRejected() throws {
        var set = AutoFillDomainRuleSet.empty
        let first = try #require(AutoFillDomainRule(rawPattern: "example.com", kind: .block))
        let duplicate = try #require(AutoFillDomainRule(rawPattern: "HTTPS://EXAMPLE.COM/", kind: .block))
        let addedFirst = set.add(first)
        #expect(addedFirst)
        let addedDuplicate = set.add(duplicate)
        #expect(!addedDuplicate)
        #expect(set.rules.count == 1)

        let allow = try #require(AutoFillDomainRule(rawPattern: "example.com", kind: .allow))
        let addedAllow = set.add(allow)
        #expect(addedAllow, "不同类型允许共存")
        #expect(set.rules.count == 2)
    }

    @Test("删除规则按 id 生效，未知 id 返回 false")
    func removingRuleById() throws {
        var set = AutoFillDomainRuleSet.empty
        let rule = try #require(AutoFillDomainRule(rawPattern: "example.com", kind: .block))
        set.add(rule)
        let removed = set.remove(id: rule.id)
        #expect(removed)
        #expect(set.isEmpty)
        let removedAgain = set.remove(id: rule.id)
        #expect(!removedAgain)
    }

    // MARK: - 编解码

    @Test("规则集合可以编码后原样解码")
    func codecRoundTrips() throws {
        var set = AutoFillDomainRuleSet.empty
        set.add(try #require(AutoFillDomainRule(rawPattern: "*.example.com", kind: .block, note: "工作账号")))
        set.add(try #require(AutoFillDomainRule(rawPattern: "login.example.com", kind: .allow)))

        let data = try AutoFillDomainRuleCodec.encode(set)
        let decoded = try AutoFillDomainRuleCodec.decode(data)
        #expect(decoded == set)
        #expect(decoded.rules.first?.note == "工作账号")
    }

    @Test("旧数据缺少 version/rules 时按空集合解码")
    func codecToleratesLegacyPayload() throws {
        let legacy = Data("{}".utf8)
        let decoded = try AutoFillDomainRuleCodec.decode(legacy)
        #expect(decoded.isEmpty)
        #expect(decoded.version == AutoFillDomainRuleSet.currentVersion)
    }

    @Test("内存存储按 vault 隔离")
    func memoryStoreIsolatesVaults() async throws {
        let store = MemoryAutoFillDomainRuleStore()
        var set = AutoFillDomainRuleSet.empty
        set.add(try #require(AutoFillDomainRule(rawPattern: "example.com", kind: .block)))

        try await store.saveRuleSet(set, vaultID: "vault-a")
        let loaded = try await store.loadRuleSet(vaultID: "vault-a")
        #expect(loaded == set)
        let otherVault = try await store.loadRuleSet(vaultID: "vault-b")
        #expect(otherVault == nil)

        try await store.deleteRuleSet(vaultID: "vault-a")
        let afterDelete = try await store.loadRuleSet(vaultID: "vault-a")
        #expect(afterDelete == nil)
    }
}
