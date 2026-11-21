import Testing
import Foundation
import MonicaStorage

// MARK: - 纯模型：归一化 / 版本化 / 容错解码

@Test func customFieldsNormalizeTrimsAndReorders() {
    let extras = VaultItemExtras(
        itemID: " item-1 ",
        itemKind: .login,
        customFields: [
            VaultCustomField(fieldID: "b", label: "  第二  ", kind: .text, value: "  值 B  ", order: 5),
            VaultCustomField(fieldID: "a", label: "第一", kind: .hiddenText, value: "  隐藏值  ", order: 1),
            VaultCustomField(fieldID: "blank", label: "   ", kind: .text, value: "   ", order: 3)
        ]
    ).normalized()

    #expect(extras.itemID == "item-1")
    #expect(extras.customFields.map(\.fieldID) == ["a", "b"])
    #expect(extras.customFields.map(\.order) == [0, 1])
    #expect(extras.customFields.first?.label == "第一")
    #expect(extras.customFields.first?.value == "隐藏值")
    #expect(extras.schemaVersion == VaultItemExtras.currentSchemaVersion)
}

@Test func customFieldsGenerateStableFieldIDWhenMissing() throws {
    let extras = VaultItemExtras(
        itemID: "item-2",
        customFields: [VaultCustomField(fieldID: "  ", label: "备注", kind: .text, value: "x")]
    ).normalized()

    let fieldID = try #require(extras.customFields.first?.fieldID)
    #expect(!fieldID.trimmingCharacters(in: .whitespaces).isEmpty)
    // 归一化结果再次归一化时保持同一个 fieldID。
    #expect(extras.normalized().customFields.first?.fieldID == fieldID)
}

@Test func extrasPayloadRoundTripsAllFourKinds() throws {
    let extras = VaultItemExtras(
        itemID: "item-3",
        itemKind: .note,
        customFields: [
            VaultCustomField(fieldID: "text", label: "备忘", kind: .text, value: "普通文本", order: 0),
            VaultCustomField(fieldID: "hidden", label: "恢复码", kind: .hiddenText, value: "S3CR3T", order: 1),
            VaultCustomField(fieldID: "url", label: "控制台", kind: .url, value: "https://example.com/admin", order: 2),
            VaultCustomField(fieldID: "date", label: "到期日", kind: .date, value: "2027-03-05", order: 3)
        ],
        relations: [VaultItemRelation(targetItemID: "target-1", targetKind: .card)]
    ).normalized()

    let json = try extras.payloadJSONString()
    let decoded = try #require(VaultItemExtras(payloadJSON: json))

    #expect(decoded == extras)
    #expect(decoded.customFields.map(\.kind) == [.text, .hiddenText, .url, .date])
    #expect(decoded.relations == [VaultItemRelation(targetItemID: "target-1", targetKind: .card)])
    // 序列化是确定性的，便于备份/比较。
    #expect(try extras.payloadJSONString() == json)
}

@Test func extrasPayloadDecodingIsForwardCompatibleAndSafeByDefault() throws {
    let legacyJSON = """
    {"schemaVersion": 9, "itemID": "legacy-item", "customFields": [
      {"label": "未知类型", "kind": "signature", "value": "v"},
      {"fieldID": "date", "label": "日期", "kind": "date", "value": "2027-13-40"}
    ], "relations": [{"targetItemID": "t1", "targetKind": "not-a-kind"}]}
    """
    let decoded = try #require(VaultItemExtras(payloadJSON: legacyJSON))

    #expect(decoded.itemID == "legacy-item")
    #expect(decoded.itemKind == nil)
    // 未知 kind 降级为普通文本，值不丢失。
    #expect(decoded.customFields.first?.kind == .text)
    #expect(decoded.customFields.first?.value == "v")
    // 未知目标类型的关系被丢弃，而不是让整条记录解析失败。
    #expect(decoded.relations.isEmpty)
    // 未来版本写回时统一收敛到当前 schema，缺省 order 由位置兜底。
    #expect(decoded.normalized().schemaVersion == VaultItemExtras.currentSchemaVersion)
    #expect(decoded.customFields.map(\.order) == [0, 1])
}

@Test func extrasPayloadWithoutItemIDIsIgnored() {
    #expect(VaultItemExtras(payloadJSON: #"{"customFields": []}"#) == nil)
    #expect(VaultItemExtras(payloadJSON: "not json") == nil)
    // 侧表条目本身的 title 可以作为兜底 itemID。
    #expect(VaultItemExtras(payloadJSON: #"{"customFields": []}"#, fallbackItemID: "fallback")?.itemID == "fallback")
}

@Test func protectedValuesAreRedactedFromDebugDescription() {
    let extras = VaultItemExtras(
        itemID: "item-4",
        customFields: [
            VaultCustomField(label: "恢复码", kind: .hiddenText, value: "SECRET-VALUE-123"),
            VaultCustomField(label: "备注", kind: .text, value: "可见值")
        ]
    )
    let description = String(describing: extras)

    #expect(!description.contains("SECRET-VALUE-123"))
    #expect(!description.contains("可见值"))
    #expect(description.contains("protectedFields: 1"))
    #expect(description.contains("fields: 2"))
}

@Test func maskedValueDoesNotLeakLength() {
    let short = VaultCustomField(label: "a", kind: .hiddenText, value: "ab")
    let long = VaultCustomField(label: "b", kind: .hiddenText, value: String(repeating: "x", count: 64))

    #expect(short.displayValue() == "••••••••")
    #expect(long.displayValue() == "••••••••")
    #expect(short.displayValue(revealed: true) == "ab")
    #expect(VaultCustomField(label: "c", kind: .text, value: "明文").displayValue() == "明文")
}

@Test func relationPayloadStoresStableIDsOnly() throws {
    let extras = VaultItemExtras(
        itemID: "item-5",
        relations: [
            VaultItemRelation(targetItemID: "target-id-1", targetKind: .login),
            VaultItemRelation(targetItemID: "target-id-1", targetKind: .login),
            VaultItemRelation(targetItemID: "item-5", targetKind: .login)
        ]
    )
    let json = try extras.payloadJSONString()

    #expect(json.contains("target-id-1"))
    #expect(json.contains("\"targetKind\""))
    // 去重、剔除自引用，标题永远不会被写进关系表。
    #expect(VaultItemExtras(payloadJSON: json)?.relations.count == 1)
    #expect(!json.contains("title"))
}

@Test func dateCodingIsUTCDayStable() throws {
    let date = try #require(VaultCustomFieldDateCoding.date(from: "2027-03-05"))
    #expect(VaultCustomFieldDateCoding.string(from: date) == "2027-03-05")
    #expect(VaultCustomFieldDateCoding.date(from: " 2027-03-05 ") != nil)
    #expect(VaultCustomFieldDateCoding.date(from: "not-a-date") == nil)
}

@Test func urlValidationAcceptsEmptyAndAbsoluteLinks() {
    #expect(VaultCustomFieldValidation.isValidURLValue(""))
    #expect(VaultCustomFieldValidation.isValidURLValue(" https://example.com "))
    #expect(VaultCustomFieldValidation.isValidURLValue("mailto:someone@example.com"))
    #expect(!VaultCustomFieldValidation.isValidURLValue("example.com"))
    #expect(!VaultCustomFieldValidation.isValidURLValue("not a url"))
}

// MARK: - 关联解析：单层、可追溯、不递归

@Test func relationResolutionHandlesBidirectionalLinksWithoutRecursion() {
    let itemA = "item-a"
    let itemB = "item-b"
    let descriptors = [
        VaultItemDescriptor(itemID: itemA, kind: .login, title: "A", isDeleted: false),
        VaultItemDescriptor(itemID: itemB, kind: .note, title: "B", isDeleted: false)
    ]

    let resolvedA = VaultItemRelationResolver.resolve(
        [VaultItemRelation(targetItemID: itemB, targetKind: .note)],
        descriptors: descriptors
    )
    let resolvedB = VaultItemRelationResolver.resolve(
        [VaultItemRelation(targetItemID: itemA, targetKind: .login)],
        descriptors: descriptors
    )

    #expect(resolvedA.map(\.status) == [.available])
    #expect(resolvedA.first?.targetTitle == "B")
    #expect(resolvedB.map(\.status) == [.available])
    #expect(resolvedB.first?.targetTitle == "A")
    // 单层解析：解析 A 不会把 B 的关系带出来，因此 A↔B 不会展开成无限链路。
    #expect(resolvedA.count == 1)
    #expect(resolvedB.count == 1)
}

@Test func relationResolutionMarksDeletedAndMissingTargets() {
    let descriptors = [
        VaultItemDescriptor(itemID: "alive", kind: .login, title: "仍在", isDeleted: false),
        VaultItemDescriptor(itemID: "trashed", kind: .login, title: "已删除", isDeleted: true)
    ]
    let resolved = VaultItemRelationResolver.resolve(
        [
            VaultItemRelation(targetItemID: "alive", targetKind: .login),
            VaultItemRelation(targetItemID: "trashed", targetKind: .login),
            VaultItemRelation(targetItemID: "gone", targetKind: .note)
        ],
        descriptors: descriptors
    )

    #expect(resolved.map(\.status) == [.available, .deleted, .missing])
    #expect(resolved[1].status.isBroken)
    #expect(resolved[1].targetTitle == "已删除")
    #expect(resolved[2].targetTitle == nil)
}

@Test func relationResolutionFlagsKindMismatch() {
    let resolved = VaultItemRelationResolver.resolve(
        [VaultItemRelation(targetItemID: "same-id", targetKind: .card)],
        descriptors: [
            VaultItemDescriptor(itemID: "same-id", kind: .login, title: "类型变了", isDeleted: false)
        ]
    )

    #expect(resolved.map(\.status) == [.kindMismatch])
    #expect(resolved.first?.targetKind == .card)
    #expect(resolved.first?.targetTitle == "类型变了")
}

@Test func relationResolutionIgnoresDuplicateDescriptors() {
    let descriptors = [
        VaultItemDescriptor(itemID: "dup", kind: .login, title: "第一份", isDeleted: false),
        VaultItemDescriptor(itemID: "dup", kind: .login, title: "第二份", isDeleted: false)
    ]
    let resolved = VaultItemRelationResolver.resolve(
        [VaultItemRelation(targetItemID: "dup", targetKind: .login)],
        descriptors: descriptors
    )

    #expect(resolved.count == 1)
    #expect(resolved.first?.status == .available)
    #expect(resolved.first?.targetTitle == "第一份")
}

// MARK: - 真实 MDBX 保险库：保存 / 重开 / 改条目 / 移动 / 备份恢复

@Test func itemExtrasSurviveReopenMoveAndBackupCopyOnRealVault() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("monica-extras-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let vaultURL = directory.appendingPathComponent("vault.mdbx")
    let password = "extras vault password 123!"
    let deviceID = "swiftpm-extras-test"
    let hiddenSecret = "S3CR3T-HIDDEN-VALUE-9f2a"

    let engine = MDBXLocalVaultEngine()
    let handle = try engine.createVault(at: vaultURL, password: password, deviceID: deviceID)
    let descriptor = LocalVaultDescriptor(fileURL: vaultURL, displayName: "Extras")
    let repository = LocalVaultEntryRepository(
        session: LocalVaultSession(descriptor: descriptor, handle: handle, state: .unlocked),
        engine: engine
    )

    let project = try repository.createProject(title: "个人")
    let secondProject = try repository.createProject(title: "工作")
    let entry = try repository.createLoginEntry(
        projectID: project.id,
        draft: LocalLoginEntryDraft(
            title: "GitHub",
            username: "octocat",
            password: "p@ssw0rd",
            url: "https://github.com"
        )
    )
    let target = try repository.createLoginEntry(
        projectID: project.id,
        draft: LocalLoginEntryDraft(
            title: "邮箱",
            username: "octocat@example.com",
            password: "another",
            url: "https://mail.example.com"
        )
    )

    let extras = VaultItemExtras(
        itemID: entry.id,
        itemKind: .login,
        customFields: [
            VaultCustomField(fieldID: "f-hidden", label: "恢复码", kind: .hiddenText, value: hiddenSecret, order: 0),
            VaultCustomField(fieldID: "f-text", label: " 账号备注 ", kind: .text, value: "  只在保险库里  ", order: 1),
            VaultCustomField(fieldID: "f-url", label: "控制台", kind: .url, value: "https://console.example.com", order: 2),
            VaultCustomField(fieldID: "f-date", label: "到期日", kind: .date, value: "2027-03-05", order: 3)
        ],
        relations: [VaultItemRelation(targetItemID: target.id, targetKind: .login)]
    )
    let saved = try repository.saveItemExtras(projectID: project.id, extras: extras)

    #expect(saved.customFields.map(\.fieldID) == ["f-hidden", "f-text", "f-url", "f-date"])
    #expect(saved.customFields.first(where: { $0.fieldID == "f-text" })?.label == "账号备注")
    #expect(saved.customFields.first(where: { $0.fieldID == "f-hidden" })?.value == hiddenSecret)

    // 编辑条目本身（改名/改密码）不能把侧表冲掉。
    _ = try repository.updateLoginEntry(
        projectID: project.id,
        entryID: entry.id,
        draft: LocalLoginEntryDraft(
            title: "GitHub 主账号",
            username: "octocat",
            password: "new-password",
            url: "https://github.com"
        )
    )
    #expect(try repository.listItemExtras(projectID: project.id)[entry.id] == saved)

    // 删除目标条目：侧表仍在，解析结果是“已删除/不可用链接”。
    try repository.deleteLoginEntry(projectID: project.id, entryID: target.id)
    let deletedTargets = try repository.listDeletedLoginEntries(projectID: project.id)
    let descriptorsAfterDelete = [entry.id: VaultItemDescriptor(itemID: entry.id, kind: .login, title: "GitHub 主账号", isDeleted: false)]
        .merging(
            deletedTargets.reduce(into: [String: VaultItemDescriptor]()) { partial, targetEntry in
                partial[targetEntry.id] = VaultItemDescriptor(
                    itemID: targetEntry.id,
                    kind: .login,
                    title: targetEntry.title,
                    isDeleted: true
                )
            },
            uniquingKeysWith: { current, _ in current }
        )
    let resolvedAfterDelete = VaultItemRelationResolver.resolve(
        try #require(repository.listItemExtras(projectID: project.id)[entry.id]?.relations),
        descriptors: Array(descriptorsAfterDelete.values)
    )
    #expect(resolvedAfterDelete.map(\.status) == [.deleted])
    #expect(resolvedAfterDelete.first?.targetTitle == "邮箱")

    // 恢复目标后链接重新可用。
    _ = try repository.restoreLoginEntry(projectID: project.id, entryID: target.id)
    let restoredDescriptors = try repository.listLoginEntries(projectID: project.id).map {
        VaultItemDescriptor(itemID: $0.id, kind: .login, title: $0.title, isDeleted: false)
    }
    let resolvedAfterRestore = VaultItemRelationResolver.resolve(
        try #require(repository.listItemExtras(projectID: project.id)[entry.id]?.relations),
        descriptors: restoredDescriptors
    )
    #expect(resolvedAfterRestore.map(\.status) == [.available])

    // 关闭 → 重开：侧表完整往返。
    engine.closeVault(handle)
    let reopened = try engine.openVault(at: vaultURL, password: password, deviceID: deviceID)
    let reopenedRepository = LocalVaultEntryRepository(
        session: LocalVaultSession(
            descriptor: descriptor,
            handle: reopened,
            state: .unlocked
        ),
        engine: engine
    )
    #expect(try reopenedRepository.listItemExtras(projectID: project.id)[entry.id] == saved)

    // 换分类后侧表跟随，旧分类不再残留。
    _ = try reopenedRepository.moveEntry(
        kind: .login,
        entryID: entry.id,
        fromProjectID: project.id,
        toProjectID: secondProject.id
    )
    #expect(try reopenedRepository.listItemExtras(projectID: project.id)[entry.id] == nil)
    #expect(try reopenedRepository.listItemExtras(projectID: secondProject.id)[entry.id] == saved)

    // 备份/恢复等价于整库文件拷贝：副本里侧表与隐藏值仍在。
    engine.closeVault(reopened)
    let backupURL = directory.appendingPathComponent("backup.mdbx")
    try FileManager.default.copyItem(at: vaultURL, to: backupURL)
    let backupHandle = try engine.openVault(at: backupURL, password: password, deviceID: deviceID)
    let backupRepository = LocalVaultEntryRepository(
        session: LocalVaultSession(
            descriptor: LocalVaultDescriptor(fileURL: backupURL, displayName: "Backup"),
            handle: backupHandle,
            state: .unlocked
        ),
        engine: engine
    )
    #expect(try backupRepository.listItemExtras(projectID: secondProject.id)[entry.id] == saved)
    engine.closeVault(backupHandle)

    // 受保护值不能以明文出现在保险库文件字节里（MDBX 静态加密）。
    let rawVaultBytes = try Data(contentsOf: vaultURL)
    #expect(rawVaultBytes.range(of: Data(hiddenSecret.utf8)) == nil)
    #expect(rawVaultBytes.range(of: Data("只在保险库里".utf8)) == nil)
}
