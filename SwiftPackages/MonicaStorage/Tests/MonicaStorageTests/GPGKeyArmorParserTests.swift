import Foundation
import Testing
import MonicaStorage

// MARK: - 固定测试向量
//
// 这些 armored 文本是**按 RFC 4880 / RFC 9580 构造的确定性向量**（不是从网络上抓的真人公钥），
// 覆盖 v4 RSA、v4 Ed25519（GnuPG 传统曲线 OID）、v6 Ed25519、带口令私钥、吊销签名，
// 以及未知算法 / v3 / 截断等错误路径。
//
// 指纹期望值由 Python 的 hashlib（独立实现）按规范公式算好后写死：
//   v4: SHA-1(0x99 || 2 字节长度 || 公钥 packet body)
//   v6: SHA-256(0x9B || 4 字节长度 || 公钥 packet body)
// 这样测试验证的是「解析 + 指纹」本身的正确性，而不是拿同一份实现自证。

/// v4 RSA 2048，创建于 2026-01-01T00:00:00Z，自签名声明 365 天过期，
/// User ID 为 "Monica GPG Test (issue 12) <gpg@example.com>"。
private let armoredRSAv4 = """
-----BEGIN PGP PUBLIC KEY BLOCK-----

xv8AAAENBGlVuQABCADAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAh
IiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/QEFCQ0RFRkdISUpLTE1OT1BR
UlNUVVZXWFlaW1xdXl9gYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1+f4CB
goOEhYaHiImKi4yNjo+QkZKTlJWWl5iZmpucnZ6foKGio6SlpqeoqaqrrK2ur7Cx
srO0tba3uLm6u7y9vr/AwcLDxMXGx8jJysvMzc7P0NHS09TV1tfY2drb3N3e3+Dh
4uPk5ebn6Onq6+zt7u/w8fLz9PX29/j5+vv8/f7/ABEBAAHNLE1vbmljYSBHUEcg
VGVzdCAoaXNzdWUgMTIpIDxncGdAZXhhbXBsZS5jb20+whMEEwEIAAYFCQHhM4AA
AAAAAAd/
=1uzF
-----END PGP PUBLIC KEY BLOCK-----
"""

private let rsaFingerprint = "B4EE5CC5FAF44DA36140A804A1715DFFCBC907E0"
private let rsaKeyID = "A1715DFFCBC907E0"

/// v4 Ed25519（算法 22 + GnuPG 曲线 OID 1.3.6.1.4.1.11591.15.1）。
private let armoredEd25519v4 = """
-----BEGIN PGP PUBLIC KEY BLOCK-----

xjIEZVPxABYJKwYBBAHaRw8BAP0RERERERERERERERERERERERERERERERERERER
EREREc0dRWQyNTUxOSBUZXN0IDxlZEBleGFtcGxlLmNvbT4=
=gO2t
-----END PGP PUBLIC KEY BLOCK-----
"""

private let ed25519Fingerprint = "D045A8438107F4C5D49A5E5C3FEEE384421864E2"

/// v6 Ed25519（RFC 9580：算法 27 + 4 字节材料长度，指纹用 SHA-256）。
private let armoredEd25519v6 = """
-----BEGIN PGP PUBLIC KEY BLOCK-----

xioGZ3SFgBsAAAAgIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiLNIFY2
IEVkMjU1MTkgVGVzdCA8djZAZXhhbXBsZS5jb20+
=b7YD
-----END PGP PUBLIC KEY BLOCK-----
"""

private let v6Fingerprint = "4120664D1A235448E51F0C06B8706A2A1BAA4F027A087CAAB554E1D5D155E563"

/// 与 `armoredRSAv4` 同一把主密钥，但以 PRIVATE KEY BLOCK 导出，私钥材料用口令加密（S2K usage = 254）。
private let armoredSecretKey = """
-----BEGIN PGP PRIVATE KEY BLOCK-----

xf8AAAEgBGlVuQABCADAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAh
IiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/QEFCQ0RFRkdISUpLTE1OT1BR
UlNUVVZXWFlaW1xdXl9gYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1+f4CB
goOEhYaHiImKi4yNjo+QkZKTlJWWl5iZmpucnZ6foKGio6SlpqeoqaqrrK2ur7Cx
srO0tba3uLm6u7y9vr/AwcLDxMXGx8jJysvMzc7P0NHS09TV1tfY2drb3N3e3+Dh
4uPk5ebn6Onq6+zt7u/w8fLz9PX29/j5+vv8/f7/ABEBAAH+CQCqqqqqqqqqqqqq
qqqqqqqqzSxNb25pY2EgR1BHIFRlc3QgKGlzc3VlIDEyKSA8Z3BnQGV4YW1wbGUu
Y29tPsITBBMBCAAGBQkB4TOAAAAAAAAHfw==
=hf9f
-----END PGP PRIVATE KEY BLOCK-----
"""

/// 同一把 RSA 主密钥，紧跟一个 type 0x20（key revocation）签名。
private let armoredRevoked = """
-----BEGIN PGP PUBLIC KEY BLOCK-----

xv8AAAENBGlVuQABCADAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAh
IiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/QEFCQ0RFRkdISUpLTE1OT1BR
UlNUVVZXWFlaW1xdXl9gYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1+f4CB
goOEhYaHiImKi4yNjo+QkZKTlJWWl5iZmpucnZ6foKGio6SlpqeoqaqrrK2ur7Cx
srO0tba3uLm6u7y9vr/AwcLDxMXGx8jJysvMzc7P0NHS09TV1tfY2drb3N3e3+Dh
4uPk5ebn6Onq6+zt7u/w8fLz9PX29/j5+vv8/f7/ABEBAAHNLE1vbmljYSBHUEcg
VGVzdCAoaXNzdWUgMTIpIDxncGdAZXhhbXBsZS5jb20+wg0EIAEIAAAAAAAAAAd/
=fFry
-----END PGP PUBLIC KEY BLOCK-----
"""

/// 未知公钥算法 ID 99。
private let armoredUnknownAlgorithm = """
-----BEGIN PGP PUBLIC KEY BLOCK-----

xgYEaVW5AGM=
=PJ11
-----END PGP PUBLIC KEY BLOCK-----
"""

/// 已废弃的 v3 密钥 packet。
private let armoredVersion3 = """
-----BEGIN PGP PUBLIC KEY BLOCK-----

xgkDaVW5AAEBAAE=
=oXsp
-----END PGP PUBLIC KEY BLOCK-----
"""

/// packet 头声明 60 字节 body，实际只剩 7 字节。
private let armoredTruncated = """
-----BEGIN PGP PUBLIC KEY BLOCK-----

xjwEaVW5AAEA
=4PgT
-----END PGP PUBLIC KEY BLOCK-----
"""

// MARK: - 测试

@Suite("GPG 密钥 armored 导入解析")
struct GPGKeyArmorParserTests {
    @Test("v4 RSA 公钥：算法、指纹、key ID、User ID 与自签名过期时间")
    func parsesV4RSAKey() throws {
        let metadata = try GPGKeyArmorParser.parse(armoredRSAv4)

        #expect(metadata.keyVersion == 4)
        #expect(metadata.algorithmID == 1)
        #expect(metadata.algorithm == "RSA 2048")
        #expect(metadata.fingerprint == rsaFingerprint)
        #expect(metadata.fingerprint.count == 40)
        #expect(metadata.keyID == rsaKeyID)
        #expect(metadata.keyCreatedAt == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(metadata.keyExpiresAt == Date(timeIntervalSince1970: 1_767_225_600 + 31_536_000))
        #expect(metadata.userID == "Monica GPG Test (issue 12) <gpg@example.com>")
        #expect(metadata.ownerName == "Monica GPG Test")
        #expect(metadata.ownerEmail == "gpg@example.com")
        #expect(metadata.isSecretKey == false)
        #expect(metadata.isRevoked == false)
        #expect(metadata.formattedFingerprint == "B4EE 5CC5 FAF4 4DA3 6140 A804 A171 5DFF CBC9 07E0")
    }

    @Test("v4 Ed25519 通过曲线 OID 识别算法")
    func parsesV4Ed25519Key() throws {
        let metadata = try GPGKeyArmorParser.parse(armoredEd25519v4)

        #expect(metadata.keyVersion == 4)
        #expect(metadata.algorithmID == 22)
        #expect(metadata.algorithm == "Ed25519")
        #expect(metadata.fingerprint == ed25519Fingerprint)
        #expect(metadata.keyID == "3FEEE384421864E2")
        #expect(metadata.keyExpiresAt == nil)
        #expect(metadata.userID == "Ed25519 Test <ed@example.com>")
        #expect(metadata.isSecretKey == false)
    }

    @Test("v6 Ed25519：64 位指纹用 SHA-256，key ID 取指纹前 16 位")
    func parsesV6Ed25519Key() throws {
        let metadata = try GPGKeyArmorParser.parse(armoredEd25519v6)

        #expect(metadata.keyVersion == 6)
        #expect(metadata.algorithmID == 27)
        #expect(metadata.algorithm == "Ed25519")
        #expect(metadata.fingerprint == v6Fingerprint)
        #expect(metadata.fingerprint.count == 64)
        #expect(metadata.keyID == "4120664D1A235448")
        #expect(metadata.keyCreatedAt == Date(timeIntervalSince1970: 1_735_689_600))
        #expect(metadata.isSecretKey == false)
    }

    @Test("私钥块：识别 S2K usage，只标记「受口令保护」，不解密也不校验口令")
    func parsesEncryptedSecretKey() throws {
        let metadata = try GPGKeyArmorParser.parse(armoredSecretKey)

        #expect(metadata.isSecretKey)
        #expect(metadata.secretKeyIsEncrypted)
        #expect(metadata.fingerprint == rsaFingerprint)
        #expect(metadata.keyID == rsaKeyID)
        #expect(metadata.algorithm == "RSA 2048")
    }

    @Test("出现主密钥吊销签名时标记 isRevoked（不做签名验证）")
    func parsesRevocationSignature() throws {
        let metadata = try GPGKeyArmorParser.parse(armoredRevoked)

        #expect(metadata.isRevoked)
        #expect(metadata.fingerprint == rsaFingerprint)
    }

    @Test("armor 头/尾与 CRLF、缺失 CRC 都能容错")
    func toleratesArmorVariants() throws {
        let crlf = armoredRSAv4.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(try GPGKeyArmorParser.parse(crlf).fingerprint == rsaFingerprint)

        let withoutChecksum = armoredRSAv4
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("=") }
            .joined(separator: "\n")
        #expect(try GPGKeyArmorParser.parse(withoutChecksum).fingerprint == rsaFingerprint)

        let withVersionHeader = armoredRSAv4.replacingOccurrences(
            of: "-----BEGIN PGP PUBLIC KEY BLOCK-----\n",
            with: "-----BEGIN PGP PUBLIC KEY BLOCK-----\nVersion: GnuPG v2.4.5\nComment: Monica\n"
        )
        #expect(try GPGKeyArmorParser.parse(withVersionHeader).fingerprint == rsaFingerprint)
    }

    @Test("损坏的 armor 给出可恢复的具体错误")
    func reportsRecoverableArmorErrors() {
        #expect(throws: GPGKeyImportError.emptyInput) {
            try GPGKeyArmorParser.parse("   \n  ")
        }
        #expect(throws: GPGKeyImportError.missingArmorHeader) {
            try GPGKeyArmorParser.parse("hello world")
        }
        #expect(throws: GPGKeyImportError.unsupportedArmorType("SIGNATURE")) {
            try GPGKeyArmorParser.parse(
                "-----BEGIN PGP SIGNATURE-----\n\nAAAA\n-----END PGP SIGNATURE-----"
            )
        }
        #expect(throws: GPGKeyImportError.missingArmorFooter) {
            try GPGKeyArmorParser.parse("-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nAAAA")
        }
        #expect(throws: GPGKeyImportError.invalidBase64) {
            try GPGKeyArmorParser.parse(
                "-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n!!!!\n-----END PGP PUBLIC KEY BLOCK-----"
            )
        }
        #expect(throws: GPGKeyImportError.armorChecksumMismatch) {
            try GPGKeyArmorParser.parse(armoredRSAv4.replacingOccurrences(of: "=1uzF", with: "=2uzF"))
        }
        #expect(throws: GPGKeyImportError.unsupportedAlgorithm(99)) {
            try GPGKeyArmorParser.parse(armoredUnknownAlgorithm)
        }
        #expect(throws: GPGKeyImportError.unsupportedKeyVersion(3)) {
            try GPGKeyArmorParser.parse(armoredVersion3)
        }
        #expect(throws: GPGKeyImportError.truncatedKeyMaterial) {
            try GPGKeyArmorParser.parse(armoredTruncated)
        }
    }

    @Test("指纹分组与过期判断")
    func formatsFingerprintAndExpiration() {
        #expect(GPGKeyMetadata.groupFingerprint("aabbccdd") == "AABB CCDD")
        #expect(GPGKeyMetadata.groupFingerprint("aabbccd") == "AABB CCD")
        #expect(GPGKeyMetadata.groupFingerprint("  ") == "")

        let expired = GPGKeyMetadata(
            keyVersion: 4,
            algorithmID: 1,
            algorithm: "RSA 2048",
            fingerprint: rsaFingerprint,
            keyID: rsaKeyID,
            keyCreatedAt: Date(timeIntervalSince1970: 1_767_225_600),
            keyExpiresAt: Date(timeIntervalSinceNow: -60),
            userID: "",
            ownerName: "",
            ownerEmail: "",
            isSecretKey: false,
            secretKeyIsEncrypted: false,
            isRevoked: false
        )
        #expect(expired.isExpired)
        #expect(expired.keyExpiresAt != nil)

        let noExpiration = GPGKeyMetadata(
            keyVersion: 4,
            algorithmID: 1,
            algorithm: "RSA 2048",
            fingerprint: rsaFingerprint,
            keyID: rsaKeyID,
            keyCreatedAt: Date(timeIntervalSince1970: 1_767_225_600),
            keyExpiresAt: nil,
            userID: "",
            ownerName: "",
            ownerEmail: "",
            isSecretKey: false,
            secretKeyIsEncrypted: false,
            isRevoked: false
        )
        #expect(noExpiration.isExpired == false)
    }

    @Test("公钥与私钥指纹不一致的错误文案包含两个指纹")
    func describesFingerprintMismatch() {
        let error = GPGKeyImportError.fingerprintMismatch(
            publicKey: rsaFingerprint,
            privateKey: ed25519Fingerprint
        )
        let description = error.errorDescription ?? ""
        #expect(description.contains("指纹不一致"))
        #expect(description.contains("B4EE 5CC5"))
        #expect(description.contains("D045 A843"))
    }
}
