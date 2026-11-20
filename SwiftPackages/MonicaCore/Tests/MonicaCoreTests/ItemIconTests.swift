import Foundation
import Testing
import MonicaCore

@Suite("条目图标稳定标识")
struct ItemIconTests {
    @Test func storageValueRoundTrips() {
        let symbol = ItemIcon.symbol("key.fill")
        #expect(symbol.storageValue == "sf:key.fill")
        #expect(ItemIcon(storageValue: "sf:key.fill") == symbol)

        let catalog = ItemIcon.catalog("bank")
        #expect(catalog.storageValue == "catalog:bank")
        #expect(ItemIcon(storageValue: "catalog:bank") == catalog)
    }

    @Test func storageValueIsStableAcrossLanguages() throws {
        // 存储值只能是稳定 id，展示名不参与编码。
        let encoded = try JSONEncoder().encode(ItemIcon.catalog("bank"))
        #expect(String(decoding: encoded, as: UTF8.self) == #""catalog:bank""#)
        #expect(ItemIcon.catalog("bank").storageValue == "catalog:bank")
        #expect(ItemIconCatalog.entry(id: "bank")?.displayName == "银行")
    }

    @Test func corruptStorageValuesAreRejected() {
        #expect(ItemIcon(storageValue: "") == nil)
        #expect(ItemIcon(storageValue: "key.fill") == nil)
        #expect(ItemIcon(storageValue: "sf:") == nil)
        #expect(ItemIcon(storageValue: "catalog:") == nil)
        #expect(ItemIcon(storageValue: "emoji:🔑") == nil)
        #expect(ItemIcon(storageValue: "SF:key.fill") == nil)
    }

    @Test func unknownSymbolFallsBackToKey() {
        let unknown = ItemIcon.symbol("definitely.not.a.symbol")
        #expect(unknown.isResolved == false)
        #expect(unknown.resolvedSystemName == "key.fill")
        #expect(ItemIcon.fallbackSymbol == "key.fill")

        let known = ItemIcon.symbol("creditcard")
        #expect(known.isResolved)
        #expect(known.resolvedSystemName == "creditcard")
    }

    @Test func unknownCatalogIDKeepsFallbackOfKind() {
        let unknown = ItemIcon.catalog("no-such-category")
        #expect(unknown.isResolved == false)
        // 未知目录项最终回落到通用 SF Symbol，而不是空白。
        #expect(unknown.resolvedSystemName == ItemIcon.fallbackSymbol)
        #expect(ItemIcon.defaultSymbol(forKind: "login") == "key.fill")
    }

    @Test func catalogEntriesAreWellFormed() {
        let ids = ItemIconCatalog.entries.map(\.id)
        #expect(ids.count >= 12)
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(id == id.lowercased())
            #expect(ItemIconCatalog.contains(id: id))
            #expect(ItemIconCatalog.isKnownSymbol(ItemIconCatalog.entry(id: id)!.symbolName))
        }
        #expect(ItemIconCatalog.entry(id: "BANK") != nil)
        #expect(ItemIconCatalog.entry(id: "missing") == nil)
    }

    /// 旧值（Android 传输过来的类型、中文标签、裸 SF 名）都要迁移，且迁移结果可再次存储。
    @Test func legacyValuesMigrate() {
        #expect(ItemIcon.migrated(fromLegacy: nil) == nil)
        #expect(ItemIcon.migrated(fromLegacy: "") == nil)
        #expect(ItemIcon.migrated(fromLegacy: "NONE") == nil)
        #expect(ItemIcon.migrated(fromLegacy: "SIMPLE_ICON") == nil)
        #expect(ItemIcon.migrated(fromLegacy: "UPLOADED") == nil)

        #expect(ItemIcon.migrated(fromLegacy: "steam") == .catalog("social"))
        #expect(ItemIcon.migrated(fromLegacy: "bank") == .catalog("bank"))
        #expect(ItemIcon.migrated(fromLegacy: "银行") == .catalog("bank"))
        #expect(ItemIcon.migrated(fromLegacy: "key.fill") == .symbol("key.fill"))
        #expect(ItemIcon.migrated(fromLegacy: "key.fill")?.storageValue == "sf:key.fill")

        for legacy in ["steam", "银行", "key.fill", "catalog:card", "sf:wifi"] {
            let migrated = ItemIcon.migrated(fromLegacy: legacy)
            #expect(migrated != nil, "\(legacy) 应该能迁移")
            if let migrated {
                #expect(ItemIcon(storageValue: migrated.storageValue) == migrated)
            }
        }
    }

    @Test func defaultSymbolCoversEveryVaultKind() {
        for kind in ["login", "password", "totp", "note", "card", "identity", "passkey", "sshKey", "apiToken", "wifi", "send", "attachmentRef"] {
            let symbol = ItemIcon.defaultSymbol(forKind: kind)
            #expect(ItemIconCatalog.isKnownSymbol(symbol), "\(kind) 的默认符号 \(symbol) 不在白名单")
        }
        #expect(ItemIcon.defaultSymbol(forKind: "unknown") == "key.fill")
        #expect(ItemIcon.defaultSymbol(forKind: "WIFI") == "wifi")
    }

    @Test func encodedFormIsADocumentedString() throws {
        let data = try JSONEncoder().encode([ItemIcon.symbol("wifi"), .catalog("mail")])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json == #"["sf:wifi","catalog:mail"]"#)

        let decoded = try JSONDecoder().decode([ItemIcon].self, from: Data(json.utf8))
        #expect(decoded == [.symbol("wifi"), .catalog("mail")])
    }
}
