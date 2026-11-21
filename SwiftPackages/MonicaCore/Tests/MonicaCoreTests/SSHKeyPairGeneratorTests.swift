import CryptoKit
import Foundation
import Testing

@testable import MonicaCore

// MARK: - 已知向量

/// RFC 8032 §7.1 TEST 1 的 Ed25519 seed 与公钥。
private let rfc8032SeedHex = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
private let rfc8032PublicKeyHex = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
/// 由上面的 blob 算出的 OpenSSH 公钥行与指纹（同时用 `ssh-keygen` 校验过）。
private let rfc8032PublicKeyLine =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINdamAGCsQq31Uv+08lkBzoO4XLz2qYjJa8CGmj3B1Ea"
private let rfc8032Fingerprint = "SHA256:bbXpuKG6zhzdmnxq256TlqzFBzRl2f6OOg722cYNbU8"

private let sshKeygenPath = "/usr/bin/ssh-keygen"
private let sshKeygenAvailable = FileManager.default.isExecutableFile(atPath: sshKeygenPath)

private func data(hex: String) -> Data {
    var bytes: [UInt8] = []
    var value = hex
    while value.count >= 2 {
        let pair = value.prefix(2)
        value.removeFirst(2)
        bytes.append(UInt8(pair, radix: 16) ?? 0)
    }
    return Data(bytes)
}

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func ed25519KeyPair(comment: String = "") throws -> SSHKeyPair {
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: data(hex: rfc8032SeedHex))
    return try SSHKeyPairGenerator.keyPair(privateKey: privateKey, comment: comment)
}

// MARK: - wire format 读取

private struct SSHBlobReader {
    let data: Data
    private var index = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool {
        index == data.count
    }

    var remaining: Int {
        data.count - index
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw SSHBlobError.truncated }
        var value: UInt32 = 0
        for _ in 0..<4 {
            value = (value << 8) | UInt32(data[data.startIndex + index])
            index += 1
        }
        return value
    }

    mutating func readString() throws -> Data {
        let length = Int(try readUInt32())
        guard remaining >= length else { throw SSHBlobError.truncated }
        let start = data.startIndex + index
        let value = data.subdata(in: start..<(start + length))
        index += length
        return value
    }

    mutating func readText() throws -> String {
        guard let text = String(data: try readString(), encoding: .utf8) else {
            throw SSHBlobError.truncated
        }
        return text
    }

    mutating func readRemainingBytes() -> [UInt8] {
        let start = data.startIndex + index
        let bytes = [UInt8](data[start...])
        index = data.count
        return bytes
    }
}

private enum SSHBlobError: Error {
    case truncated
    case invalid
}

/// 把 `ssh-ed25519 AAAA... comment` 拆成算法名与 blob。
private func splitPublicKeyLine(_ line: String) throws -> (algorithm: String, blob: Data, comment: String?) {
    let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2,
          let blob = Data(base64Encoded: parts[1])
    else {
        throw SSHBlobError.invalid
    }
    return (parts[0], blob, parts.count > 2 ? parts[2] : nil)
}

private func decodePEM(_ pem: String, header: String) throws -> Data {
    let begin = "-----BEGIN \(header)-----"
    let end = "-----END \(header)-----"
    let lines = pem.split(separator: "\n").map(String.init)
    guard lines.first == begin, lines.last == end else {
        throw SSHBlobError.invalid
    }
    let body = lines.dropFirst().dropLast().joined()
    guard let data = Data(base64Encoded: body) else {
        throw SSHBlobError.invalid
    }
    return data
}

/// 解析 OpenSSH 私钥容器，返回各段。
private func parseOpenSSHPrivateKey(
    _ pem: String
) throws -> (publicBlob: Data, privateSection: Data, cipher: String, kdf: String) {
    let blob = try decodePEM(pem, header: "OPENSSH PRIVATE KEY")
    let magic = Data("openssh-key-v1\0".utf8)
    guard blob.starts(with: magic) else { throw SSHBlobError.invalid }
    var reader = SSHBlobReader(blob.dropFirst(magic.count))
    let cipher = try reader.readText()
    let kdf = try reader.readText()
    _ = try reader.readString()             // kdf options
    guard try reader.readUInt32() == 1 else { throw SSHBlobError.invalid }
    let publicBlob = try reader.readString()
    let privateSection = try reader.readString()
    guard reader.isAtEnd else { throw SSHBlobError.invalid }
    return (publicBlob, privateSection, cipher, kdf)
}

private func runSSHKeygen(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: sshKeygenPath)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw SSHBlobError.invalid
    }
    return text
}

// MARK: - Ed25519

@Test("固定 seed 生成的 Ed25519 公钥行与 RFC 8032 向量一致")
func ed25519KnownVectorPublicKey() throws {
    let keyPair = try ed25519KeyPair()
    #expect(keyPair.algorithm == .ed25519)
    #expect(keyPair.keySize == 256)
    #expect(keyPair.publicKeyOpenSSH == rfc8032PublicKeyLine)
    #expect(keyPair.fingerprintSHA256 == rfc8032Fingerprint)
    #expect(keyPair.format == "OPENSSH")
    #expect(keyPair.privateKeyOpenSSH.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
    #expect(keyPair.privateKeyOpenSSH.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
}

@Test("Ed25519 公钥 blob 是 length-prefixed 的算法名加 32 字节公钥")
func ed25519WireFormat() throws {
    let keyPair = try ed25519KeyPair()
    let parts = try splitPublicKeyLine(keyPair.publicKeyOpenSSH)
    #expect(parts.algorithm == "ssh-ed25519")
    #expect(parts.comment == nil)

    var reader = SSHBlobReader(parts.blob)
    #expect(try reader.readText() == "ssh-ed25519")
    let rawPublicKey = try reader.readString()
    #expect(rawPublicKey.count == 32)
    #expect(hex(rawPublicKey) == rfc8032PublicKeyHex)
    #expect(reader.isAtEnd)

    // 指纹是公钥 blob 的 SHA-256，base64 无 padding。
    let digest = SHA256.hash(data: parts.blob)
    let expected = "SHA256:" + Data(digest).base64EncodedString()
        .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    #expect(keyPair.fingerprintSHA256 == expected)
    #expect(!keyPair.fingerprintSHA256.hasSuffix("="))
}

@Test("Ed25519 私钥容器可被解析成 none/none 的 openssh-key-v1")
func ed25519PrivateKeyContainer() throws {
    let keyPair = try ed25519KeyPair(comment: "monica@ios")
    let parsed = try parseOpenSSHPrivateKey(keyPair.privateKeyOpenSSH)
    #expect(parsed.cipher == "none")
    #expect(parsed.kdf == "none")

    let publicParts = try splitPublicKeyLine(keyPair.publicKeyOpenSSH)
    #expect(parsed.publicBlob == publicParts.blob)
    #expect(publicParts.comment == "monica@ios")

    var reader = SSHBlobReader(parsed.privateSection)
    let firstCheck = try reader.readUInt32()
    let secondCheck = try reader.readUInt32()
    #expect(firstCheck == secondCheck)
    #expect(try reader.readText() == "ssh-ed25519")
    let embeddedPublicKey = try reader.readString()
    #expect(embeddedPublicKey == data(hex: rfc8032PublicKeyHex))
    let embeddedPrivateKey = try reader.readString()
    #expect(embeddedPrivateKey.count == 64)
    #expect(hex(embeddedPrivateKey.prefix(32)) == rfc8032SeedHex)
    #expect(hex(embeddedPrivateKey.suffix(32)) == rfc8032PublicKeyHex)
    #expect(try reader.readText() == "monica@ios")
    // 剩余字节是按 1,2,3… 递增的 padding，总量小于一个块（8 字节）。
    let padding = reader.readRemainingBytes()
    #expect(padding.count < 8)
    let expectedPadding = padding.isEmpty ? [] : Array(1...padding.count).map(UInt8.init)
    #expect(padding == expectedPadding)
}

@Test("公钥注释里的换行会被清洗，避免拼出两行公钥")
func publicKeyCommentSanitizing() throws {
    let keyPair = try ed25519KeyPair(comment: "  monica@example.com\nssh-ed25519 injected  ")
    #expect(keyPair.publicKeyOpenSSH == rfc8032PublicKeyLine + " monica@example.com ssh-ed25519 injected")

    // 私钥里的注释同样是清洗后的单行，不含换行注入。
    let parsed = try parseOpenSSHPrivateKey(keyPair.privateKeyOpenSSH)
    var reader = SSHBlobReader(parsed.privateSection)
    _ = try reader.readUInt32()
    _ = try reader.readUInt32()
    _ = try reader.readText()
    _ = try reader.readString()
    _ = try reader.readString()
    #expect(try reader.readText() == "monica@example.com ssh-ed25519 injected")
}

@Test("SSHKeyPair 的默认描述不含私钥")
func sshKeyPairDescriptionRedactsPrivateKey() throws {
    let keyPair = try ed25519KeyPair()
    #expect(keyPair.description.contains("SHA256:"))
    #expect(!keyPair.description.contains("PRIVATE KEY"))
    #expect(!keyPair.debugDescription.contains("BEGIN OPENSSH PRIVATE KEY"))
    #expect(keyPair.debugDescription.contains("<redacted>"))
}

// MARK: - RSA

@Test("RSA 2048 生成正确的位数、公钥 blob 与可解析的私钥")
func rsa2048Shape() throws {
    let keyPair = try SSHKeyPairGenerator.generate(algorithm: .rsa, rsaKeySize: 2048, comment: "rsa@test")
    #expect(keyPair.algorithm == .rsa)
    #expect(keyPair.keySize == 2048)

    let parts = try splitPublicKeyLine(keyPair.publicKeyOpenSSH)
    #expect(parts.algorithm == "ssh-rsa")
    #expect(parts.comment == "rsa@test")

    var reader = SSHBlobReader(parts.blob)
    #expect(try reader.readText() == "ssh-rsa")
    let exponentBytes = try reader.readString()
    #expect(hex(exponentBytes) == "010001")   // 65537
    let modulusBytes = try reader.readString()
    // mpint 是正整数：2048 位模数的最高位为 1，因此会补一个 0x00 前缀（257 字节）。
    #expect(modulusBytes.count == 257)
    #expect(modulusBytes.first == 0x00)
    #expect(modulusBytes.dropFirst().first.map { $0 & 0x80 != 0 } == true)
    #expect(reader.isAtEnd)

    let digest = SHA256.hash(data: parts.blob)
    #expect(keyPair.fingerprintSHA256
        == "SHA256:" + Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "=")))

    let parsed = try parseOpenSSHPrivateKey(keyPair.privateKeyOpenSSH)
    #expect(parsed.cipher == "none")
    #expect(parsed.kdf == "none")
    #expect(parsed.publicBlob == parts.blob)

    var privateReader = SSHBlobReader(parsed.privateSection)
    let firstCheck = try privateReader.readUInt32()
    let secondCheck = try privateReader.readUInt32()
    #expect(firstCheck == secondCheck)
    #expect(try privateReader.readText() == "ssh-rsa")
    let privateModulus = try privateReader.readString()
    #expect(privateModulus == modulusBytes)
    let privateExponentPublic = try privateReader.readString()
    #expect(privateExponentPublic == exponentBytes)
    let privateExponent = try privateReader.readString()
    #expect(!privateExponent.isEmpty)
    _ = try privateReader.readString()      // iqmp
    _ = try privateReader.readString()      // p
    _ = try privateReader.readString()      // q
    #expect(try privateReader.readText() == "rsa@test")

    // PEM 每行 base64 不超过 70 个字符，与 Android / ssh-keygen 常见输出一致。
    let bodyLines = keyPair.privateKeyOpenSSH.split(separator: "\n").dropFirst().dropLast()
    #expect(bodyLines.allSatisfy { $0.count <= 70 })
}

@Test("RSA 只接受 2048 / 3072 / 4096", arguments: [1024, 1536, 2049, 8192])
func rsaRejectsUnsupportedSize(keySize: Int) throws {
    #expect(throws: SSHKeyGenerationError.unsupportedRSAKeySize(keySize)) {
        try SSHKeyPairGenerator.generate(algorithm: .rsa, rsaKeySize: keySize)
    }
}

@Test("RSA 3072 生成的位数与请求一致")
func rsa3072Bits() throws {
    let keyPair = try SSHKeyPairGenerator.generate(algorithm: .rsa, rsaKeySize: 3072)
    #expect(keyPair.keySize == 3072)
    let parts = try splitPublicKeyLine(keyPair.publicKeyOpenSSH)
    var reader = SSHBlobReader(parts.blob)
    _ = try reader.readText()
    _ = try reader.readString()
    let modulus = try reader.readString()
    #expect(modulus.count == 385)
}

@Test("RSA 4096 生成的位数与请求一致")
func rsa4096Bits() throws {
    let keyPair = try SSHKeyPairGenerator.generate(algorithm: .rsa, rsaKeySize: 4096)
    #expect(keyPair.keySize == 4096)
    let parts = try splitPublicKeyLine(keyPair.publicKeyOpenSSH)
    var reader = SSHBlobReader(parts.blob)
    _ = try reader.readText()
    _ = try reader.readString()
    let modulus = try reader.readString()
    #expect(modulus.count == 513)
}

// MARK: - 私钥存储

@Test("SSHPrivateKeyReference 只接受 monica-ssh:// 引用")
func sshPrivateKeyReferenceParsing() {
    let reference = SSHPrivateKeyReference.reference(for: "A1B2-C3")
    #expect(reference == "monica-ssh://A1B2-C3")
    #expect(SSHPrivateKeyReference.identifier(from: reference) == "A1B2-C3")
    #expect(SSHPrivateKeyReference.isReference(reference))
    #expect(SSHPrivateKeyReference.identifier(from: "monica-ssh://") == nil)
    #expect(SSHPrivateKeyReference.identifier(from: "monica-ssh://a b") == nil)
    #expect(SSHPrivateKeyReference.identifier(from: "https://example.com") == nil)
    #expect(!SSHPrivateKeyReference.isReference("-----BEGIN OPENSSH PRIVATE KEY-----"))
}

@Test("内存私钥存储可保存、读取并删除")
func memorySSHPrivateKeyStoreRoundTrip() throws {
    let store = MemorySSHPrivateKeyStore()
    let keyPair = try ed25519KeyPair()
    let reference = try store.savePrivateKey(keyPair.privateKeyOpenSSH, identifier: "key-1")
    #expect(reference == "monica-ssh://key-1")
    #expect(try store.loadPrivateKey(reference: reference) == keyPair.privateKeyOpenSSH)
    #expect(store.contains(reference: reference))

    try store.deletePrivateKey(reference: reference)
    #expect(try store.loadPrivateKey(reference: reference) == nil)
    #expect(!store.contains(reference: reference))
    // 删除不存在的私钥不报错，回滚路径才能幂等。
    try store.deletePrivateKey(reference: reference)

    #expect(throws: SSHPrivateKeyStoreError.invalidReference) {
        try store.savePrivateKey(keyPair.privateKeyOpenSSH, identifier: "")
    }
    #expect(throws: SSHPrivateKeyStoreError.invalidReference) {
        try store.loadPrivateKey(reference: "not-a-reference")
    }
}

// MARK: - ssh-keygen 互操作（macOS 测试宿主）

@Test(
    "生成的密钥能被 ssh-keygen 读回，且指纹一致",
    .enabled(if: sshKeygenAvailable)
)
func sshKeygenInterop() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("monica-ssh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let ed25519 = try ed25519KeyPair(comment: "ed25519@interop")
    let ed25519KeyURL = directory.appendingPathComponent("id_ed25519")
    try ed25519.privateKeyOpenSSH.write(to: ed25519KeyURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ed25519KeyURL.path)

    let derived = try runSSHKeygen(["-y", "-f", ed25519KeyURL.path])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(derived.hasPrefix(rfc8032PublicKeyLine))
    #expect(derived.contains("ed25519@interop"))

    let ed25519PublicURL = directory.appendingPathComponent("id_ed25519.pub")
    try ed25519.publicKeyOpenSSH.write(to: ed25519PublicURL, atomically: true, encoding: .utf8)
    let fingerprintLine = try runSSHKeygen(["-l", "-f", ed25519PublicURL.path])
    #expect(fingerprintLine.contains(rfc8032Fingerprint))

    let rsa = try SSHKeyPairGenerator.generate(algorithm: .rsa, rsaKeySize: 2048, comment: "rsa@interop")
    let rsaKeyURL = directory.appendingPathComponent("id_rsa")
    try rsa.privateKeyOpenSSH.write(to: rsaKeyURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rsaKeyURL.path)
    let rsaPublicURL = directory.appendingPathComponent("id_rsa.pub")
    try rsa.publicKeyOpenSSH.write(to: rsaPublicURL, atomically: true, encoding: .utf8)

    let rsaDerived = try runSSHKeygen(["-y", "-f", rsaKeyURL.path])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let derivedFields = rsaDerived.split(separator: " ").map(String.init)
    let publicFields = rsa.publicKeyOpenSSH.split(separator: " ").map(String.init)
    #expect(derivedFields.count >= 2 && publicFields.count >= 2)
    #expect(derivedFields.first == "ssh-rsa")
    #expect(derivedFields.dropFirst().first == publicFields.dropFirst().first)

    let rsaFingerprintLine = try runSSHKeygen(["-l", "-f", rsaPublicURL.path])
    #expect(rsaFingerprintLine.contains(rsa.fingerprintSHA256))
}
