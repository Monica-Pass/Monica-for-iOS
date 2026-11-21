import MonicaCore
import XCTest

@testable import Monica

@MainActor
final class AutoFillDomainRuleControllerTests: XCTestCase {
    func testAddDraftRulePersistsAndSurvivesReload() async {
        let store = MemoryAutoFillDomainRuleStore()
        let controller = AutoFillDomainRuleController(store: store)
        await controller.attach(vaultID: "vault-a")

        controller.draftPattern = "https://Example.com/login"
        controller.draftKind = .block
        controller.draftNote = "工作账号"
        let added = await controller.addDraftRule()
        XCTAssertTrue(added, controller.statusMessage ?? "")
        XCTAssertEqual(controller.blockedRules.count, 1)
        XCTAssertEqual(controller.blockedRules.first?.pattern, "example.com")
        XCTAssertEqual(controller.blockedRules.first?.note, "工作账号")
        XCTAssertEqual(controller.draftPattern, "", "添加成功后应清空草稿")

        let reloaded = AutoFillDomainRuleController(store: store)
        await reloaded.attach(vaultID: "vault-a")
        XCTAssertEqual(reloaded.blockedRules.map(\.pattern), ["example.com"])
    }

    func testInvalidPatternShowsErrorAndKeepsNothing() async {
        let controller = AutoFillDomainRuleController(store: MemoryAutoFillDomainRuleStore())
        await controller.attach(vaultID: "vault-a")

        controller.draftPattern = "exa mple.com"
        let added = await controller.addDraftRule()
        XCTAssertFalse(added)
        XCTAssertTrue(controller.statusIsError)
        XCTAssertTrue(controller.ruleSet.isEmpty)
    }

    func testDuplicateRuleIsRejectedWithMessage() async {
        let controller = AutoFillDomainRuleController(store: MemoryAutoFillDomainRuleStore())
        await controller.attach(vaultID: "vault-a")

        controller.draftPattern = "example.com"
        let first = await controller.addDraftRule()
        XCTAssertTrue(first)

        controller.draftPattern = "EXAMPLE.com."
        let second = await controller.addDraftRule()
        XCTAssertFalse(second, "同类型同域名不应重复添加")
        XCTAssertEqual(controller.blockedRules.count, 1)
    }

    func testAllowRuleOverridesBlockRuleForFiltering() async {
        let controller = AutoFillDomainRuleController(store: MemoryAutoFillDomainRuleStore())
        await controller.attach(vaultID: "vault-a")

        controller.draftPattern = "example.com"
        controller.draftKind = .block
        _ = await controller.addDraftRule()

        controller.draftPattern = "login.example.com"
        controller.draftKind = .allow
        _ = await controller.addDraftRule()

        XCTAssertTrue(controller.hidesServiceIdentifier("https://admin.example.com"))
        XCTAssertFalse(controller.hidesServiceIdentifier("https://login.example.com"))
        XCTAssertFalse(controller.hidesServiceIdentifier("https://other.test"))
    }

    func testRemovePersistsDeletion() async {
        let store = MemoryAutoFillDomainRuleStore()
        let controller = AutoFillDomainRuleController(store: store)
        await controller.attach(vaultID: "vault-a")

        controller.draftPattern = "example.com"
        _ = await controller.addDraftRule()
        guard let rule = controller.blockedRules.first else {
            return XCTFail("应当有一条规则")
        }

        await controller.remove(rule)
        XCTAssertTrue(controller.ruleSet.isEmpty)

        let reloaded = AutoFillDomainRuleController(store: store)
        await reloaded.attach(vaultID: "vault-a")
        XCTAssertTrue(reloaded.ruleSet.isEmpty)
    }

    func testDetachClearsInMemoryRulesButKeepsStorage() async {
        let store = MemoryAutoFillDomainRuleStore()
        let controller = AutoFillDomainRuleController(store: store)
        await controller.attach(vaultID: "vault-a")

        controller.draftPattern = "example.com"
        _ = await controller.addDraftRule()

        controller.detach()
        XCTAssertFalse(controller.isVaultUnlocked)
        XCTAssertTrue(controller.ruleSet.isEmpty)

        await controller.attach(vaultID: "vault-a")
        XCTAssertEqual(controller.blockedRules.count, 1, "锁库不应删除已保存的规则")
    }

    func testAddWithoutUnlockedVaultFails() async {
        let controller = AutoFillDomainRuleController(store: MemoryAutoFillDomainRuleStore())
        controller.draftPattern = "example.com"
        let added = await controller.addDraftRule()
        XCTAssertFalse(added)
        XCTAssertTrue(controller.statusIsError)
    }
}
