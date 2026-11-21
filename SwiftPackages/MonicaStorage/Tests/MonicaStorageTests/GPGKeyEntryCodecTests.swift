import Foundation
import Testing
@testable import MonicaStorage

/// GPG 密钥条目的 **payload 编解码** 契约：
/// 只验证结构化字段原样落库、原样读回，不涉及任何 OpenPGP 密码学能力。
@Suite("GPG 密钥条目 payload 编解码")
struct GPGKeyEntryCodecTests {
    private static let fingerprint = "B4EE5CC5FAF44DA36140A804A1715DFFCBC907E0"
    private static let keyID = "A1715DFFCBC907E0"
    private static let publicKeyArmor = """
    -----BEGIN PGP PUBLIC KEY BLOCK-----

    mQENBFvT2QABCADQ0dummyarmorforstoragetestsonly0000000000000000000000000000
    =AAAA
    -----END PGP PUBLIC KEY BLOCK-----
    """
    private static let privateKeyArmor = """
    -----BEGIN PGP PRIVATE KEY BLOCK-----

    lQOYBFvT2QABCADQ0dummyarmorforstoragetestsonly0000000000000000000000000000
    =AAAA
    -----END PGP PRIVATE KEY BLOCK-----
    """

    private static func makeMetadata(
        keyExpiresAt: Date? = Date(timeIntervalSince1970: 1_799_409_600),
        isRevoked: Bool = false
    ) -> GPGKeyMetadata {
        GPGKeyMetadata(
            keyVersion: 4,
            algorithmID: 1,
            algorithm: "RSA 2048",
            fingerprint: fingerprint,
            keyID: keyID,
            keyCreatedAt: Date(timeIntervalSince1970: 1_767_225_600),
            keyExpiresAt: keyExpiresAt,
            userID: "Monica GPG Test (issue 12) <gpg@example.com>",
            ownerName: "Monica GPG Test (issue 12)",
            ownerEmail: "gpg@example.com",
            isSecretKey: false,
            secretKeyIsEncrypted: false,
            isRevoked: isRevoked
        )
    }

    private static func makeDraft(
        metadata: GPGKeyMetadata? = nil,
        publicKeyArmor: String = publicKeyArmor,
        privateKeyArmor: String = ""
    ) -> LocalGPGKeyEntryDraft {
        LocalGPGKeyEntryDraft(
            title: "Monica GPG Test",
            notes: "导入自公司密钥服务器",
            armoredPublicKey: publicKeyArmor,
            armoredPrivateKey: privateKeyArmor,
            metadata: metadata ?? makeMetadata(),
            importedAt: Date(timeIntervalSince1970: 1_767_300_000)
        )
    }

    /// payload 必须经 JSONSerialization 走一遍（真实落库就是 JSON 字符串），
    /// 再解码回条目，确保写入侧与读取侧的键名/类型不会漂移。
    @Test("payload 经 JSON 往返后字段完全一致")
    func payloadSurvivesJSONRoundTrip() throws {
        let draft = Self.makeDraft(privateKeyArmor: Self.privateKeyArmor)
        let json = try JSONSerialization.data(withJSONObject: draft.parityPayload, options: [.sortedKeys])
        let object = try JSONSerialization.jsonObject(with: json)
        let payload = try #require(object as? [String: Any])

        let entry = LocalGPGKeyEntry(
            id: "gpg-entry-1",
            projectID: "project-1",
            title: draft.title,
            favorite: true,
            payload: payload
        )

        #expect(entry.fingerprint == Self.fingerprint)
        #expect(entry.keyID == Self.keyID)
        #expect(entry.formattedFingerprint == "B4EE 5CC5 FAF4 4DA3 6140 A804 A171 5DFF CBC9 07E0")
        #expect(entry.algorithm == "RSA 2048")
        #expect(entry.keyVersion == 4)
        #expect(entry.algorithmID == 1)
        #expect(entry.ownerEmail == "gpg@example.com")
        #expect(entry.userID == "Monica GPG Test (issue 12) <gpg@example.com>")
        #expect(entry.keyCreatedAt == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(entry.keyExpiresAt == Date(timeIntervalSince1970: 1_799_409_600))
        #expect(entry.importedAt == Date(timeIntervalSince1970: 1_767_300_000))
        #expect(entry.notes == "导入自公司密钥服务器")
        #expect(entry.armoredPublicKey == Self.publicKeyArmor)
        #expect(entry.armoredPrivateKey == Self.privateKeyArmor)
        #expect(entry.hasPrivateKey)
        #expect(entry.favorite)
        #expect(entry.isRevoked == false)
        #expect(entry.statusSummary == "未过期")
    }

    /// 没有过期时间时用 0 占位，读回必须是 nil 而不是 1970 年。
    @Test("未声明过期时间时读回 nil")
    func missingExpirationDecodesAsNil() throws {
        let draft = Self.makeDraft(metadata: Self.makeMetadata(keyExpiresAt: nil))
        let entry = LocalGPGKeyEntry(
            id: "gpg-entry-2",
            projectID: "project-1",
            title: draft.title,
            favorite: false,
            payload: draft.parityPayload
        )
        #expect(entry.keyExpiresAt == nil)
        #expect(entry.metadata.keyExpiresAt == nil)
        #expect(entry.hasPrivateKey == false)
    }

    /// draft 携带的 metadata 与条目计算属性必须一致，避免 UI 展示和落库字段对不上。
    @Test("draft 元数据与条目计算属性一致")
    func draftMetadataMatchesEntry() throws {
        let draft = Self.makeDraft()
        let entry = LocalGPGKeyEntry(
            id: "gpg-entry-3",
            projectID: "project-1",
            title: draft.title,
            favorite: false,
            payload: draft.parityPayload
        )
        #expect(entry.metadata.algorithmID == 1)
        #expect(entry.metadata.keyVersion == 4)
        #expect(entry.statusSummary == "未过期")
        #expect(entry.isExpired == false)
    }
}
