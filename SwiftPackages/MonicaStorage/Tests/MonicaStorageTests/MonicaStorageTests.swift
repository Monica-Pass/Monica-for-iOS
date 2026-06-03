import Testing
import Foundation
import CryptoKit
import MonicaStorage

@Test func storageBaselineDocumentsMdbxAsPrimaryStore() {
    #expect(MonicaStorageBaseline.primaryStore == "MDBX")
}

@Test func paritySourcesDescribeMultiSourceCompatibilityTargets() {
    #expect(VaultSource.mdbx.displayName == "MDBX")
    #expect(VaultSource.keepass.displayName == "KeePass")
    #expect(VaultSource.bitwarden.displayName == "Bitwarden")
    #expect(VaultSource.androidBackup.displayName == "Android 备份")
    #expect(VaultSource.csvImport.displayName == "CSV 导入")
    #expect(VaultSource.phaseOneSources == [.mdbx])
    #expect(VaultSource.longTermSources == [.mdbx, .keepass, .bitwarden, .androidBackup, .csvImport])
}

@Test func keepPassFormatInspectorDetectsKdbxAndLegacyKdbContainers() throws {
    let kdbx = Data([
        0x03, 0xD9, 0xA2, 0x9A,
        0x67, 0xFB, 0x4B, 0xB5,
        0x00, 0x00, 0x04, 0x00
    ])
    let legacyKdb = Data([
        0x03, 0xD9, 0xA2, 0x9A,
        0x65, 0xFB, 0x4B, 0xB5
    ])

    #expect(KeePassFormatInspector.detect(kdbx, sourceName: "vault.kdbx") == .kdbx)
    #expect(KeePassFormatInspector.detect(legacyKdb, sourceName: "old.kdb") == .legacyKdb)
    #expect(KeePassFormatInspector.detect(Data("not a database".utf8), sourceName: "old.kdb") == .legacyKdb)
    #expect(KeePassFormatInspector.detect(Data("not a database".utf8), sourceName: "notes.txt") == .unknown)

    let report = KeePassFormatInspector.inspect(kdbx, sourceName: "vault.kdbx")
    #expect(report.format == .kdbx)
    #expect(report.status == .requiresCredentials)
    #expect(report.issue == nil)

    #expect(throws: KeePassOperationError.self) {
        try KeePassFormatInspector.ensureKdbxSupported(legacyKdb, sourceName: "old.kdb")
    }
}

@Test func keepPassFormatInspectorSummarizesKdbx4PublicCryptoHeaderWithoutSecrets() throws {
    let header = makeKdbx4Header(
        cipherID: Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]),
        compressionFlags: Data([0x01, 0x00, 0x00, 0x00]),
        kdfParameters: makeKdbxVariantDictionary(
            uuid: Data([0x9E, 0x29, 0x8B, 0x19, 0x56, 0xDB, 0x47, 0x73, 0xB2, 0x3D, 0xFC, 0x3E, 0xC6, 0xF0, 0xA1, 0xE6])
        )
    )

    let report = KeePassFormatInspector.inspect(header, sourceName: "personal.kdbx")

    #expect(report.headerSummary?.displayName == "KDBX 4")
    #expect(report.headerSummary?.cryptoSummary?.cipher == .aes256)
    #expect(report.headerSummary?.cryptoSummary?.compression == .gzip)
    #expect(report.headerSummary?.cryptoSummary?.kdf == .argon2id)
    #expect(report.headerSummary?.cryptoSummary?.displaySummary == "AES-256，GZip，Argon2id")
    #expect(!report.headerSummary!.cryptoSummary!.displaySummary.contains("database-password"))
    #expect(!report.headerSummary!.cryptoSummary!.displaySummary.contains("key-file-secret"))
}

@Test func keepPassKdbxPayloadEnvelopeSplitsHeaderFieldsAndEncryptedPayloadWithoutSecrets() throws {
    let header = makeKdbx4Header(
        cipherID: Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]),
        compressionFlags: Data([0x01, 0x00, 0x00, 0x00]),
        kdfParameters: makeKdbxVariantDictionary(
            uuid: Data([0x9E, 0x29, 0x8B, 0x19, 0x56, 0xDB, 0x47, 0x73, 0xB2, 0x3D, 0xFC, 0x3E, 0xC6, 0xF0, 0xA1, 0xE6])
        )
    )
    let encryptedPayload = Data("encrypted-payload-bytes".utf8)
    let envelope = try KeePassKdbxPayloadEnvelope.parse(header + encryptedPayload)

    #expect(envelope.headerSummary.displayName == "KDBX 4")
    #expect(envelope.headerSummary.cryptoSummary?.displaySummary == "AES-256，GZip，Argon2id")
    #expect(envelope.headerByteRange == 0..<header.count)
    #expect(envelope.headerBytes == header)
    #expect(envelope.encryptedPayload == encryptedPayload)
    #expect(envelope.headerFields[2] == Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]))
    #expect(envelope.headerFields[3] == Data([0x01, 0x00, 0x00, 0x00]))
    #expect(envelope.displaySummary == "KDBX 4，header 89 bytes，payload 23 bytes，AES-256，GZip，Argon2id")
    #expect(!envelope.displaySummary.contains("database-password"))
    #expect(!envelope.displaySummary.contains("key-file-secret"))
    #expect(!envelope.displaySummary.contains("encrypted-payload-bytes"))
}

@Test func keepPassFormatInspectorParsesKdbx4Argon2KdfParametersWithoutLeakingSalt() throws {
    let salt = Data((0..<32).map(UInt8.init))
    let header = makeKdbx4Header(
        cipherID: Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]),
        compressionFlags: Data([0x01, 0x00, 0x00, 0x00]),
        kdfParameters: makeKdbxVariantDictionary(entries: [
            kdbxVariantByteArray(key: "$UUID", value: Data([0x9E, 0x29, 0x8B, 0x19, 0x56, 0xDB, 0x47, 0x73, 0xB2, 0x3D, 0xFC, 0x3E, 0xC6, 0xF0, 0xA1, 0xE6])),
            kdbxVariantByteArray(key: "S", value: salt),
            kdbxVariantUInt64(key: "I", value: 4),
            kdbxVariantUInt64(key: "M", value: 64 * 1024 * 1024),
            kdbxVariantUInt32(key: "P", value: 2),
            kdbxVariantUInt32(key: "V", value: 0x13)
        ])
    )

    let envelope = try KeePassKdbxPayloadEnvelope.parse(header + Data("encrypted".utf8))
    let parameters = envelope.headerSummary.kdfParameters

    #expect(parameters?.algorithm == .argon2id)
    #expect(parameters?.argon2?.salt == salt)
    #expect(parameters?.argon2?.iterations == 4)
    #expect(parameters?.argon2?.memoryBytes == 64 * 1024 * 1024)
    #expect(parameters?.argon2?.parallelism == 2)
    #expect(parameters?.argon2?.version == 0x13)
    #expect(parameters?.displaySummary == "Argon2id，memory 67108864 bytes，iterations 4，parallelism 2，version 19")
    #expect(!parameters!.displaySummary.contains(salt.map { String(format: "%02x", $0) }.joined()))
    #expect(!envelope.displaySummary.contains(salt.map { String(format: "%02x", $0) }.joined()))
}

@Test func keepPassFormatInspectorParsesKdbx4AesKdfParametersWithoutLeakingSeed() throws {
    let seed = Data((32..<64).map(UInt8.init))
    let header = makeKdbx4Header(
        cipherID: Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]),
        compressionFlags: Data([0x00, 0x00, 0x00, 0x00]),
        kdfParameters: makeKdbxVariantDictionary(entries: [
            kdbxVariantByteArray(key: "$UUID", value: Data([0xC9, 0xD9, 0xF3, 0x9A, 0x62, 0x8A, 0x44, 0x60, 0xBF, 0x74, 0x0D, 0x08, 0xC1, 0x8A, 0x4F, 0xEA])),
            kdbxVariantByteArray(key: "S", value: seed),
            kdbxVariantUInt64(key: "R", value: 600_000)
        ])
    )

    let report = KeePassFormatInspector.inspect(header, sourceName: "aes-kdf.kdbx")
    let parameters = report.headerSummary?.kdfParameters

    #expect(parameters?.algorithm == .aesKdf)
    #expect(parameters?.aesKdf?.seed == seed)
    #expect(parameters?.aesKdf?.rounds == 600_000)
    #expect(parameters?.displaySummary == "AES-KDF，rounds 600000")
    #expect(!parameters!.displaySummary.contains(seed.map { String(format: "%02x", $0) }.joined()))
}

@Test func keepPassFormatInspectorParsesKdbx3LegacyAesKdfParametersWithoutLeakingSeed() throws {
    let transformSeed = Data((64..<96).map(UInt8.init))
    let header = makeKdbx3Header(
        cipherID: Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]),
        compressionFlags: Data([0x01, 0x00, 0x00, 0x00]),
        masterSeed: Data(repeating: 0xB1, count: 32),
        transformSeed: transformSeed,
        transformRounds: 1_234_567,
        encryptionIV: Data(repeating: 0xC1, count: 16),
        protectedStreamKey: Data(repeating: 0xD1, count: 32),
        streamStartBytes: Data(repeating: 0xE1, count: 32),
        innerRandomStreamID: 2
    )
    let encryptedPayload = Data("encrypted-payload-secret".utf8)

    let envelope = try KeePassKdbxPayloadEnvelope.parse(header + encryptedPayload)
    let parameters = envelope.headerSummary.kdfParameters

    #expect(envelope.headerSummary.displayName == "KDBX 3")
    #expect(envelope.headerSummary.cryptoSummary?.displaySummary == "AES-256，GZip，AES-KDF")
    #expect(parameters?.algorithm == .aesKdf)
    #expect(parameters?.aesKdf?.seed == transformSeed)
    #expect(parameters?.aesKdf?.rounds == 1_234_567)
    #expect(parameters?.displaySummary == "AES-KDF，rounds 1234567")
    #expect(envelope.encryptedPayload == encryptedPayload)
    if let parameters {
        #expect(!parameters.displaySummary.contains(transformSeed.map { String(format: "%02x", $0) }.joined()))
    } else {
        Issue.record("Expected KDBX3 AES-KDF parameters")
    }
    #expect(!envelope.displaySummary.contains(transformSeed.map { String(format: "%02x", $0) }.joined()))
    #expect(!envelope.displaySummary.contains("encrypted-payload-secret"))
}

@Test func keepPassKdbxDecryptInputContextBuildsCompositeKeyWithoutLeakingSecrets() throws {
    let salt = Data((0..<32).map(UInt8.init))
    let header = makeKdbx4Header(
        cipherID: Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]),
        compressionFlags: Data([0x01, 0x00, 0x00, 0x00]),
        kdfParameters: makeKdbxVariantDictionary(entries: [
            kdbxVariantByteArray(key: "$UUID", value: Data([0x9E, 0x29, 0x8B, 0x19, 0x56, 0xDB, 0x47, 0x73, 0xB2, 0x3D, 0xFC, 0x3E, 0xC6, 0xF0, 0xA1, 0xE6])),
            kdbxVariantByteArray(key: "S", value: salt),
            kdbxVariantUInt64(key: "I", value: 4),
            kdbxVariantUInt64(key: "M", value: 64 * 1024 * 1024),
            kdbxVariantUInt32(key: "P", value: 2),
            kdbxVariantUInt32(key: "V", value: 0x13)
        ])
    )
    let encryptedPayload = Data("encrypted-payload-bytes".utf8)
    let password = "database-password"
    let keyMaterial = Data("key-file-secret".utf8)
    let candidate = KeePassCredentialCandidate(
        label: "raw/password+key",
        password: password,
        keyMaterial: keyMaterial
    )

    let context = try KeePassKdbxDecryptInputContext.build(
        database: header + encryptedPayload,
        sourceName: "personal.kdbx",
        credentialCandidate: candidate
    )

    let passwordHash = Data(SHA256.hash(data: Data(password.utf8)))
    var combined = Data()
    combined.append(passwordHash)
    combined.append(keyMaterial)

    #expect(context.sourceName == "personal.kdbx")
    #expect(context.candidateLabel == "raw/password+key")
    #expect(context.envelope.encryptedPayload == encryptedPayload)
    #expect(context.kdfParameters?.algorithm == .argon2id)
    #expect(context.credentialMaterial.passwordKey == passwordHash)
    #expect(context.credentialMaterial.keyFileKey == keyMaterial)
    #expect(context.credentialMaterial.compositeKey == Data(SHA256.hash(data: combined)))
    #expect(context.credentialMaterial.componentSummary == "password + key file")
    #expect(context.displaySummary == "KDBX 4，payload 23 bytes，Argon2id，candidate raw/password+key，password + key file")
    #expect(!context.displaySummary.contains(password))
    #expect(!context.displaySummary.contains("key-file-secret"))
    #expect(!context.displaySummary.contains(salt.map { String(format: "%02x", $0) }.joined()))
    #expect(!context.displaySummary.contains("encrypted-payload-bytes"))
}

@Test func keepPassKdbxDecryptInputContextParsesPayloadCryptoInputsWithoutLeakingSecrets() throws {
    let masterSeed = Data((64..<96).map(UInt8.init))
    let encryptionIV = Data((96..<108).map(UInt8.init))
    let innerRandomStreamKey = Data((108..<140).map(UInt8.init))
    let streamStartBytes = Data((140..<172).map(UInt8.init))
    let kdfSeed = Data((172..<204).map(UInt8.init))
    let header = makeKdbx4Header(
        cipherID: Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]),
        compressionFlags: Data([0x01, 0x00, 0x00, 0x00]),
        masterSeed: masterSeed,
        encryptionIV: encryptionIV,
        innerRandomStreamKey: innerRandomStreamKey,
        streamStartBytes: streamStartBytes,
        innerRandomStreamID: 3,
        kdfParameters: makeKdbxVariantDictionary(entries: [
            kdbxVariantByteArray(key: "$UUID", value: Data([0xC9, 0xD9, 0xF3, 0x9A, 0x62, 0x8A, 0x44, 0x60, 0xBF, 0x74, 0x0D, 0x08, 0xC1, 0x8A, 0x4F, 0xEA])),
            kdbxVariantByteArray(key: "S", value: kdfSeed),
            kdbxVariantUInt64(key: "R", value: 1)
        ])
    )
    let encryptedPayload = Data("encrypted-payload-bytes".utf8)

    let context = try KeePassKdbxDecryptInputContext.build(
        database: header + encryptedPayload,
        sourceName: "aes-kdf.kdbx",
        credentialCandidate: KeePassCredentialCandidate(
            label: "password-only",
            password: "database-password",
            keyMaterial: nil
        )
    )

    #expect(context.cryptoInputs.masterSeed == masterSeed)
    #expect(context.cryptoInputs.encryptionIV == encryptionIV)
    #expect(context.cryptoInputs.innerRandomStreamKey == innerRandomStreamKey)
    #expect(context.cryptoInputs.streamStartBytes == streamStartBytes)
    #expect(context.cryptoInputs.innerRandomStreamID == 3)
    #expect(context.cryptoInputs.innerRandomStreamAlgorithm == .chacha20)
    #expect(context.cryptoInputs.displaySummary == "master seed 32 bytes，IV 12 bytes，stream start 32 bytes，inner stream ChaCha20，inner key 32 bytes")
    #expect(context.displaySummary == "KDBX 4，payload 23 bytes，AES-KDF，candidate password-only，password，master seed 32 bytes，IV 12 bytes，stream start 32 bytes，inner stream ChaCha20，inner key 32 bytes")

    for secret in [masterSeed, encryptionIV, innerRandomStreamKey, streamStartBytes, kdfSeed] {
        let hex = secret.map { String(format: "%02x", $0) }.joined()
        #expect(!context.cryptoInputs.displaySummary.contains(hex))
        #expect(!context.displaySummary.contains(hex))
    }
    #expect(!context.displaySummary.contains("database-password"))
    #expect(!context.displaySummary.contains("encrypted-payload-bytes"))
}

@Test func keepPassKdbxAesKdfDeriverTransformsCompositeKeyWithoutLeakingSecrets() throws {
    let seed = try decodeHexData("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    let plaintextBlock = try decodeHexData("00112233445566778899aabbccddeeff")
    let expectedCipherBlock = try decodeHexData("8ea2b7ca516745bfeafc49904b496089")
    var compositeKey = Data()
    compositeKey.append(plaintextBlock)
    compositeKey.append(plaintextBlock)
    var transformedKey = Data()
    transformedKey.append(expectedCipherBlock)
    transformedKey.append(expectedCipherBlock)

    let kdfParameters = KeePassKdbxKdfParameters(
        algorithm: .aesKdf,
        aesKdf: KeePassKdbxAesKdfParameters(seed: seed, rounds: 1)
    )
    let context = KeePassKdbxDecryptInputContext(
        sourceName: "aes-kdf.kdbx",
        candidateLabel: "fixture/password+key",
        envelope: KeePassKdbxPayloadEnvelope(
            headerSummary: KeePassHeaderSummary(
                majorVersion: 4,
                minorVersion: 0,
                formatVersion: .kdbx4,
                kdfParameters: kdfParameters
            ),
            headerFields: [:],
            headerByteRange: 0..<0,
            encryptedPayload: Data("encrypted-payload-bytes".utf8)
        ),
        kdfParameters: kdfParameters,
        cryptoInputs: .empty,
        credentialMaterial: KeePassKdbxCredentialMaterial(
            passwordKey: nil,
            keyFileKey: nil,
            compositeKey: compositeKey
        )
    )

    let derived = try DefaultKeePassKdbxKeyDeriver().deriveKey(from: context)

    #expect(derived.algorithm == .aesKdf)
    #expect(derived.material == Data(SHA256.hash(data: transformedKey)))
    #expect(derived.displaySummary == "AES-KDF，rounds 1，derived key 32 bytes")
    #expect(!derived.displaySummary.contains(seed.map { String(format: "%02x", $0) }.joined()))
    #expect(!derived.displaySummary.contains(compositeKey.map { String(format: "%02x", $0) }.joined()))
    #expect(!derived.displaySummary.contains(derived.material.map { String(format: "%02x", $0) }.joined()))
    #expect(!derived.displaySummary.contains("encrypted-payload-bytes"))
}

@Test func keepPassKdbxArgon2idDeriverExecutesKdfWithoutLeakingSecrets() throws {
    let compositeKey = Data("password".utf8)
    let salt = Data("somesalt".utf8)
    let kdfParameters = KeePassKdbxKdfParameters(
        algorithm: .argon2id,
        argon2: KeePassKdbxArgon2Parameters(
            salt: salt,
            iterations: 2,
            memoryBytes: 16 * 1024,
            parallelism: 1,
            version: 0x13
        )
    )
    let context = KeePassKdbxDecryptInputContext(
        sourceName: "argon2id-kdf.kdbx",
        candidateLabel: "password-only",
        envelope: KeePassKdbxPayloadEnvelope(
            headerSummary: KeePassHeaderSummary(
                majorVersion: 4,
                minorVersion: 0,
                formatVersion: .kdbx4,
                kdfParameters: kdfParameters
            ),
            headerFields: [:],
            headerByteRange: 0..<0,
            encryptedPayload: Data("encrypted-payload-bytes".utf8)
        ),
        kdfParameters: kdfParameters,
        cryptoInputs: .empty,
        credentialMaterial: KeePassKdbxCredentialMaterial(
            passwordKey: nil,
            keyFileKey: nil,
            compositeKey: compositeKey
        )
    )

    let expectedMaterial = try decodeHexData("058202c0723cd88c24408ccac1cbf828dee63bcf3843a150ea364a1e0b4e1ff8")
    let derived = try DefaultKeePassKdbxKeyDeriver().deriveKey(from: context)

    #expect(derived.algorithm == .argon2id)
    #expect(derived.material == expectedMaterial)
    #expect(derived.displaySummary == "Argon2id，derived key 32 bytes")
    #expect(!derived.displaySummary.contains(salt.map { String(format: "%02x", $0) }.joined()))
    #expect(!derived.displaySummary.contains(compositeKey.map { String(format: "%02x", $0) }.joined()))
    #expect(!derived.displaySummary.contains(derived.material.map { String(format: "%02x", $0) }.joined()))
    #expect(!derived.displaySummary.contains("encrypted-payload-bytes"))
}

@Test func keepPassKdbxArgon2dDeriverExecutesKdfWithoutLeakingSecrets() throws {
    let compositeKey = Data("password".utf8)
    let salt = Data("somesalt".utf8)
    let kdfParameters = KeePassKdbxKdfParameters(
        algorithm: .argon2d,
        argon2: KeePassKdbxArgon2Parameters(
            salt: salt,
            iterations: 2,
            memoryBytes: 16 * 1024,
            parallelism: 1,
            version: 0x13
        )
    )
    let context = KeePassKdbxDecryptInputContext(
        sourceName: "argon2d-kdf.kdbx",
        candidateLabel: "password-only",
        envelope: KeePassKdbxPayloadEnvelope(
            headerSummary: KeePassHeaderSummary(
                majorVersion: 4,
                minorVersion: 0,
                formatVersion: .kdbx4,
                kdfParameters: kdfParameters
            ),
            headerFields: [:],
            headerByteRange: 0..<0,
            encryptedPayload: Data("encrypted-payload-bytes".utf8)
        ),
        kdfParameters: kdfParameters,
        cryptoInputs: .empty,
        credentialMaterial: KeePassKdbxCredentialMaterial(
            passwordKey: nil,
            keyFileKey: nil,
            compositeKey: compositeKey
        )
    )

    let expectedMaterial = try decodeHexData("e742c05880c44c4df5fe79937be77897a6e41ca758affc42301f1e4040e35bd2")
    let derived = try DefaultKeePassKdbxKeyDeriver().deriveKey(from: context)

    #expect(derived.algorithm == .argon2d)
    #expect(derived.material == expectedMaterial)
    #expect(derived.displaySummary == "Argon2d，derived key 32 bytes")
    #expect(!derived.displaySummary.contains(salt.map { String(format: "%02x", $0) }.joined()))
    #expect(!derived.displaySummary.contains(compositeKey.map { String(format: "%02x", $0) }.joined()))
    #expect(!derived.displaySummary.contains(derived.material.map { String(format: "%02x", $0) }.joined()))
    #expect(!derived.displaySummary.contains("encrypted-payload-bytes"))
}

@Test func keepPassKdbxMasterKeyComposerCombinesMasterSeedAndDerivedKeyWithoutLeakingSecrets() throws {
    let masterSeed = Data((32..<64).map(UInt8.init))
    let derivedMaterial = Data((64..<96).map(UInt8.init))
    let derivedKey = KeePassKdbxDerivedKey(
        algorithm: .aesKdf,
        material: derivedMaterial,
        rounds: 1
    )
    let cryptoInputs = KeePassKdbxPayloadCryptoInputs(
        masterSeed: masterSeed,
        encryptionIV: Data(repeating: 0xA1, count: 16),
        innerRandomStreamKey: Data(repeating: 0xC3, count: 32),
        streamStartBytes: Data(repeating: 0xB2, count: 32),
        innerRandomStreamID: 2
    )

    let masterKey = try DefaultKeePassKdbxMasterKeyComposer().composeMasterKey(
        from: derivedKey,
        cryptoInputs: cryptoInputs
    )

    var combined = Data()
    combined.append(masterSeed)
    combined.append(derivedMaterial)
    #expect(masterKey.algorithm == KeePassKdbxKdfAlgorithm.aesKdf)
    #expect(masterKey.material == Data(SHA256.hash(data: combined)))
    #expect(masterKey.displaySummary == "AES-KDF，master key 32 bytes")

    for secret in [masterSeed, derivedMaterial, masterKey.material] {
        let hex = secret.map { String(format: "%02x", $0) }.joined()
        #expect(!masterKey.displaySummary.contains(hex))
    }
}

@Test func keepPassKdbxAesPayloadCipherDecryptsCbcPayloadWithoutLeakingSecrets() throws {
    let masterKey = KeePassKdbxMasterKeyMaterial(
        algorithm: .aesKdf,
        material: try decodeHexData("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
    )
    let cryptoInputs = KeePassKdbxPayloadCryptoInputs(
        masterSeed: Data(repeating: 0xA1, count: 32),
        encryptionIV: try decodeHexData("000102030405060708090a0b0c0d0e0f"),
        innerRandomStreamKey: Data(repeating: 0xB2, count: 32),
        streamStartBytes: Data(repeating: 0xC3, count: 32),
        innerRandomStreamID: 2
    )
    let encryptedPayload = try decodeHexData("f58c4c04d6e5f1ba779eabfb5f7bfbd6")

    let decrypted = try DefaultKeePassKdbxPayloadCipher().decryptPayload(
        encryptedPayload,
        cipher: .aes256,
        masterKey: masterKey,
        cryptoInputs: cryptoInputs
    )

    let expectedPlaintext = try decodeHexData("6bc1bee22e409f96e93d7e117393172a")
    #expect(decrypted == expectedPlaintext)
}

@Test func keepPassKdbxChaCha20PayloadCipherDecryptsPayloadWithoutLeakingSecrets() throws {
    let masterKey = KeePassKdbxMasterKeyMaterial(
        algorithm: .aesKdf,
        material: try decodeHexData("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    )
    let cryptoInputs = KeePassKdbxPayloadCryptoInputs(
        masterSeed: Data(repeating: 0xA1, count: 32),
        encryptionIV: try decodeHexData("000000090000004a00000000"),
        innerRandomStreamKey: Data(repeating: 0xB2, count: 64),
        streamStartBytes: nil,
        innerRandomStreamID: 3
    )
    let encryptedPayload = try decodeHexData("8adc91fd9ff4f0f51b0fad50ff15d637")

    let decrypted = try DefaultKeePassKdbxPayloadCipher().decryptPayload(
        encryptedPayload,
        cipher: .chacha20,
        masterKey: masterKey,
        cryptoInputs: cryptoInputs
    )

    let expectedPlaintext = try decodeHexData("00000000000000000000000000000000")
    #expect(decrypted == expectedPlaintext)
}

@Test func keepPassKdbxTwofishPayloadCipherDecryptsCbcPayloadWithoutLeakingSecrets() throws {
    let masterKey = KeePassKdbxMasterKeyMaterial(
        algorithm: .aesKdf,
        material: Data(repeating: 0x00, count: 32)
    )
    let cryptoInputs = KeePassKdbxPayloadCryptoInputs(
        masterSeed: Data(repeating: 0xA1, count: 32),
        encryptionIV: Data(repeating: 0x00, count: 16),
        innerRandomStreamKey: Data(repeating: 0xB2, count: 32),
        streamStartBytes: nil,
        innerRandomStreamID: 2
    )
    let encryptedPayload = try decodeHexData("""
    57ff739d4dc92c1bd7fc01700cc8216f
    b07fb634f1e56d6d4c97aa3a791b3498
    """)

    let decrypted = try DefaultKeePassKdbxPayloadCipher().decryptPayload(
        encryptedPayload,
        cipher: .twofish,
        masterKey: masterKey,
        cryptoInputs: cryptoInputs
    )

    let expectedPlaintext = Data(repeating: 0x00, count: 16)
    #expect(decrypted == expectedPlaintext)
    #expect(!decrypted.description.contains(masterKey.material.map { String(format: "%02x", $0) }.joined()))
}

@Test func keePassGzipPayloadCompressorRoundTripsXmlPayloadWithoutLeakingSecrets() throws {
    let xmlPayload = Data("<KeePassFile><Root><Group><Name>secret xml</Name></Group></Root></KeePassFile>".utf8)

    let compressed = try KeePassGzipPayloadCompressor().compress(xmlPayload)
    let snapshot = try DefaultKeePassDatabaseReader().readSnapshot(
        database: compressed,
        sourceName: "writeback.xml.gz",
        credentials: KeePassUnlockCredentials(
            password: "database-password",
            keyFile: nil,
            keyFileName: nil
        )
    )

    #expect(snapshot.groupCount == 1)
    #expect(snapshot.groups.first?.title == "secret xml")
    #expect(compressed.starts(with: Data([0x1F, 0x8B])))
    #expect(!compressed.description.contains("secret xml"))
}

@Test func keepPassKdbxAesPayloadCipherEncryptsCbcPayloadWithoutLeakingSecrets() throws {
    let masterKey = KeePassKdbxMasterKeyMaterial(
        algorithm: .aesKdf,
        material: try decodeHexData("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
    )
    let cryptoInputs = KeePassKdbxPayloadCryptoInputs(
        masterSeed: Data(repeating: 0xA1, count: 32),
        encryptionIV: try decodeHexData("000102030405060708090a0b0c0d0e0f"),
        innerRandomStreamKey: Data(repeating: 0xB2, count: 32),
        streamStartBytes: Data(repeating: 0xC3, count: 32),
        innerRandomStreamID: 2
    )
    let plaintext = try decodeHexData("6bc1bee22e409f96e93d7e117393172a")

    let encrypted = try DefaultKeePassKdbxPayloadCipher().encryptPayload(
        plaintext,
        cipher: .aes256,
        masterKey: masterKey,
        cryptoInputs: cryptoInputs
    )
    let decrypted = try DefaultKeePassKdbxPayloadCipher().decryptPayload(
        encrypted,
        cipher: .aes256,
        masterKey: masterKey,
        cryptoInputs: cryptoInputs
    )

    #expect(decrypted == plaintext)
    #expect(encrypted != plaintext)

    do {
        _ = try DefaultKeePassKdbxPayloadCipher().encryptPayload(
            Data("secret xml".utf8),
            cipher: .aes256,
            masterKey: KeePassKdbxMasterKeyMaterial(algorithm: .aesKdf, material: Data("short-key-secret".utf8)),
            cryptoInputs: cryptoInputs
        )
        Issue.record("Expected invalid AES key to fail")
    } catch let error as KeePassOperationError {
        #expect(error.code == .formatUnsupported)
        #expect(!error.message.contains("secret xml"))
        #expect(!error.message.contains("short-key-secret"))
        #expect(!error.message.contains(masterKey.material.map { String(format: "%02x", $0) }.joined()))
    }
}

@Test func keepPassKdbx3BlockStreamDecoderValidatesStreamStartAndHashesBlocksWithoutLeakingSecrets() throws {
    let streamStartBytes = Data("stream-start-secret".utf8)
    let xmlPayload = Data("<KeePassFile><Meta><DatabaseName>secret xml</DatabaseName></Meta></KeePassFile>".utf8)
    let decryptedBlockStream = makeKdbx3HashedBlockStream(
        streamStartBytes: streamStartBytes,
        blocks: [xmlPayload]
    )

    let decoded = try DefaultKeePassKdbxBlockStreamDecoder().decodeBlockStream(
        decryptedBlockStream,
        context: KeePassKdbxBlockStreamContext(
            formatVersion: .kdbx3,
            streamStartBytes: streamStartBytes
        )
    )

    #expect(decoded == xmlPayload)

    var tampered = decryptedBlockStream
    let firstBlockDataOffset = streamStartBytes.count + 4 + 32 + 4
    tampered[firstBlockDataOffset] ^= 0x01
    #expect(throws: KeePassOperationError.self) {
        _ = try DefaultKeePassKdbxBlockStreamDecoder().decodeBlockStream(
            tampered,
            context: KeePassKdbxBlockStreamContext(
                formatVersion: .kdbx3,
                streamStartBytes: streamStartBytes
            )
        )
    }

    do {
        _ = try DefaultKeePassKdbxBlockStreamDecoder().decodeBlockStream(
            Data("wrong-start".utf8) + decryptedBlockStream,
            context: KeePassKdbxBlockStreamContext(
                formatVersion: .kdbx3,
                streamStartBytes: streamStartBytes
            )
        )
        Issue.record("Expected stream start validation to fail")
    } catch let error as KeePassOperationError {
        #expect(error.code == .invalidCredential)
        #expect(!error.message.contains("stream-start-secret"))
        #expect(!error.message.contains("secret xml"))
        #expect(!error.message.contains(Data(SHA256.hash(data: xmlPayload)).map { String(format: "%02x", $0) }.joined()))
    }
}

@Test func keepPassKdbx4BlockStreamDecoderValidatesHmacBlocksWithoutLeakingSecrets() throws {
    let hmacBaseKey = Data(SHA512.hash(data: Data("hmac-base-key-secret".utf8)))
    let encryptedXMLPayload = Data("<KeePassFile><Meta><DatabaseName>secret xml</DatabaseName></Meta></KeePassFile>".utf8)
    let hmacBlockStream = makeKdbx4HmacBlockStream(
        hmacBaseKey: hmacBaseKey,
        blocks: [encryptedXMLPayload]
    )

    let decoded = try DefaultKeePassKdbxBlockStreamDecoder().decodeBlockStream(
        hmacBlockStream,
        context: KeePassKdbxBlockStreamContext(
            formatVersion: .kdbx4,
            streamStartBytes: nil,
            hmacBlockBaseKey: hmacBaseKey
        )
    )

    #expect(decoded == encryptedXMLPayload)

    var tampered = hmacBlockStream
    let firstBlockDataOffset = 32 + 4
    tampered[firstBlockDataOffset] ^= 0x01
    do {
        _ = try DefaultKeePassKdbxBlockStreamDecoder().decodeBlockStream(
            tampered,
            context: KeePassKdbxBlockStreamContext(
                formatVersion: .kdbx4,
                streamStartBytes: nil,
                hmacBlockBaseKey: hmacBaseKey
            )
        )
        Issue.record("Expected HMAC validation to fail")
    } catch let error as KeePassOperationError {
        #expect(error.code == .invalidCredential)
        #expect(!error.message.contains("hmac-base-key-secret"))
        #expect(!error.message.contains("secret xml"))
        #expect(!error.message.contains(hmacBaseKey.map { String(format: "%02x", $0) }.joined()))
    }
}

@Test func keepPassKdbx3BlockStreamEncoderRoundTripsXmlPayloadWithoutLeakingSecrets() throws {
    let streamStartBytes = Data(repeating: 0x42, count: 32)
    let xmlPayload = Data("<KeePassFile><Meta><DatabaseName>secret xml</DatabaseName></Meta></KeePassFile>".utf8)
    let context = KeePassKdbxBlockStreamContext(
        formatVersion: .kdbx3,
        streamStartBytes: streamStartBytes
    )

    let encoded = try DefaultKeePassKdbxBlockStreamEncoder().encodeBlockStream(xmlPayload, context: context)
    let decoded = try DefaultKeePassKdbxBlockStreamDecoder().decodeBlockStream(encoded, context: context)

    #expect(decoded == xmlPayload)

    do {
        _ = try DefaultKeePassKdbxBlockStreamEncoder().encodeBlockStream(
            xmlPayload,
            context: KeePassKdbxBlockStreamContext(formatVersion: .kdbx3, streamStartBytes: nil)
        )
        Issue.record("Expected missing stream start bytes to fail")
    } catch let error as KeePassOperationError {
        #expect(error.code == .formatUnsupported)
        #expect(!error.message.contains("secret xml"))
        #expect(!error.message.contains(streamStartBytes.map { String(format: "%02x", $0) }.joined()))
    }
}

@Test func keepPassKdbx4BlockStreamEncoderRoundTripsXmlPayloadWithoutLeakingSecrets() throws {
    let hmacBaseKey = Data(SHA512.hash(data: Data("hmac-base-key-secret".utf8)))
    let xmlPayload = Data("<KeePassFile><Meta><DatabaseName>secret xml</DatabaseName></Meta></KeePassFile>".utf8)
    let context = KeePassKdbxBlockStreamContext(
        formatVersion: .kdbx4,
        streamStartBytes: nil,
        hmacBlockBaseKey: hmacBaseKey
    )

    let encoded = try DefaultKeePassKdbxBlockStreamEncoder().encodeBlockStream(xmlPayload, context: context)
    let decoded = try DefaultKeePassKdbxBlockStreamDecoder().decodeBlockStream(encoded, context: context)

    #expect(decoded == xmlPayload)

    var tampered = encoded
    let firstBlockDataOffset = SHA256.byteCount + 4
    tampered[firstBlockDataOffset] ^= 0x01
    #expect(throws: KeePassOperationError.self) {
        _ = try DefaultKeePassKdbxBlockStreamDecoder().decodeBlockStream(tampered, context: context)
    }

    do {
        _ = try DefaultKeePassKdbxBlockStreamEncoder().encodeBlockStream(
            xmlPayload,
            context: KeePassKdbxBlockStreamContext(formatVersion: .kdbx4, streamStartBytes: nil)
        )
        Issue.record("Expected missing HMAC key to fail")
    } catch let error as KeePassOperationError {
        #expect(error.code == .formatUnsupported)
        #expect(!error.message.contains("hmac-base-key-secret"))
        #expect(!error.message.contains("secret xml"))
        #expect(!error.message.contains(hmacBaseKey.map { String(format: "%02x", $0) }.joined()))
    }
}

@Test func keepPassKdbx4PayloadSectionWriterAddsHeaderAuthenticationWithoutLeakingSecrets() throws {
    final class FixedKeyDeriver: KeePassKdbxKeyDeriver, @unchecked Sendable {
        func deriveKey(from context: KeePassKdbxDecryptInputContext) throws -> KeePassKdbxDerivedKey {
            KeePassKdbxDerivedKey(
                algorithm: .aesKdf,
                material: Data(repeating: 0x22, count: 32),
                rounds: 1
            )
        }
    }

    final class FixedMasterKeyComposer: KeePassKdbxMasterKeyComposer, @unchecked Sendable {
        func composeMasterKey(
            from derivedKey: KeePassKdbxDerivedKey,
            cryptoInputs: KeePassKdbxPayloadCryptoInputs
        ) throws -> KeePassKdbxMasterKeyMaterial {
            KeePassKdbxMasterKeyMaterial(
                algorithm: derivedKey.algorithm,
                material: Data(repeating: 0x33, count: 32)
            )
        }
    }

    final class RecordingPayloadCipher: KeePassKdbxPayloadCipher, @unchecked Sendable {
        var payloads: [Data] = []

        func decryptPayload(
            _ encryptedPayload: Data,
            cipher: KeePassKdbxCipherAlgorithm,
            masterKey: KeePassKdbxMasterKeyMaterial,
            cryptoInputs: KeePassKdbxPayloadCryptoInputs
        ) throws -> Data {
            payloads.append(encryptedPayload)
            return Data("<KeePassFile />".utf8)
        }
    }

    let masterSeed = Data(repeating: 0x44, count: 32)
    let derivedMaterial = Data(repeating: 0x22, count: 32)
    let headerBytes = Data("header bytes secret".utf8)
    let encryptedPayload = Data("encrypted-payload-secret".utf8)
    let payloadSection = try DefaultKeePassKdbx4PayloadSectionWriter().writePayloadSection(
        encryptedPayloadBlocks: [encryptedPayload],
        headerBytes: headerBytes,
        masterSeed: masterSeed,
        derivedKey: KeePassKdbxDerivedKey(algorithm: .aesKdf, material: derivedMaterial, rounds: 1)
    )
    let kdfParameters = KeePassKdbxKdfParameters(
        algorithm: .aesKdf,
        aesKdf: KeePassKdbxAesKdfParameters(seed: Data(repeating: 0xA5, count: 32), rounds: 1)
    )
    let context = KeePassKdbxDecryptInputContext(
        sourceName: "kdbx4-writeback-section.kdbx",
        candidateLabel: "password-only",
        envelope: KeePassKdbxPayloadEnvelope(
            headerSummary: KeePassHeaderSummary(
                majorVersion: 4,
                minorVersion: 0,
                formatVersion: .kdbx4,
                cryptoSummary: KeePassKdbxCryptoSummary(cipher: .aes256, compression: KeePassKdbxCompressionAlgorithm.none, kdf: .aesKdf),
                kdfParameters: kdfParameters
            ),
            headerFields: [:],
            headerBytes: headerBytes,
            headerByteRange: 0..<0,
            encryptedPayload: payloadSection
        ),
        kdfParameters: kdfParameters,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs(
            masterSeed: masterSeed,
            encryptionIV: Data(repeating: 0x66, count: 16)
        ),
        credentialMaterial: KeePassKdbxCredentialMaterial(
            passwordKey: Data("password-key-secret".utf8),
            keyFileKey: nil,
            compositeKey: Data(repeating: 0x77, count: 32)
        )
    )
    let payloadCipher = RecordingPayloadCipher()
    let decryptor = DefaultKeePassKdbxPayloadDecryptor(
        keyDeriver: FixedKeyDeriver(),
        masterKeyComposer: FixedMasterKeyComposer(),
        payloadCipher: payloadCipher
    )

    let decoded = try decryptor.decryptPayload(context)

    #expect(decoded == Data("<KeePassFile />".utf8))
    #expect(payloadCipher.payloads == [encryptedPayload])
    #expect(payloadSection.prefix(SHA256.byteCount) == Data(SHA256.hash(data: headerBytes)))
    #expect(!payloadSection.description.contains("header bytes secret"))
    #expect(!payloadSection.description.contains("encrypted-payload-secret"))
    #expect(!payloadSection.description.contains(masterSeed.map { String(format: "%02x", $0) }.joined()))
    #expect(!payloadSection.description.contains(derivedMaterial.map { String(format: "%02x", $0) }.joined()))

    do {
        _ = try DefaultKeePassKdbx4PayloadSectionWriter().writePayloadSection(
            encryptedPayloadBlocks: [encryptedPayload],
            headerBytes: headerBytes,
            masterSeed: Data("short-master-seed-secret".utf8),
            derivedKey: KeePassKdbxDerivedKey(algorithm: .aesKdf, material: derivedMaterial, rounds: 1)
        )
        Issue.record("Expected invalid master seed to fail")
    } catch let error as KeePassOperationError {
        #expect(error.code == .formatUnsupported)
        #expect(!error.message.contains("header bytes secret"))
        #expect(!error.message.contains("encrypted-payload-secret"))
        #expect(!error.message.contains("short-master-seed-secret"))
        #expect(!error.message.contains(derivedMaterial.map { String(format: "%02x", $0) }.joined()))
    }
}

@Test func keepPassKdbx4FileAssemblerBuildsReadableDatabaseWithExistingHeaderWithoutLeakingSecrets() throws {
    let masterSeed = Data(repeating: 0xB8, count: 32)
    let encryptionIV = Data(repeating: 0xC8, count: 16)
    let transformSeed = Data(repeating: 0xA8, count: 32)
    let password = "assembled-password-secret"
    let xmlPayload = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <KeePassFile>
      <Root>
        <Group>
          <UUID>assembly-root</UUID>
          <Name>Assembly Root</Name>
          <Entry>
            <UUID>assembly-entry</UUID>
            <String><Key>Title</Key><Value>Assembled Login</Value></String>
            <String><Key>UserName</Key><Value>writer</Value></String>
            <String><Key>Password</Key><Value>assembled password</Value></String>
          </Entry>
        </Group>
      </Root>
    </KeePassFile>
    """.utf8)
    let header = makeKdbx4Header(
        cipherID: Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]),
        compressionFlags: Data([0x00, 0x00, 0x00, 0x00]),
        masterSeed: masterSeed,
        encryptionIV: encryptionIV,
        innerRandomStreamKey: Data(repeating: 0xE8, count: 32),
        innerRandomStreamID: 2,
        kdfParameters: makeKdbxVariantDictionary(entries: [
            kdbxVariantByteArray(
                key: "$UUID",
                value: Data([0xC9, 0xD9, 0xF3, 0x9A, 0x62, 0x8A, 0x44, 0x60, 0xBF, 0x74, 0x0D, 0x08, 0xC1, 0x8A, 0x4F, 0xEA])
            ),
            kdbxVariantByteArray(key: "S", value: transformSeed),
            kdbxVariantUInt64(key: "R", value: 1)
        ])
    )
    let derivedKey = try DefaultKeePassKdbxKeyDeriver().deriveKey(
        from: try KeePassKdbxDecryptInputContext.build(
            database: header + Data("placeholder".utf8),
            sourceName: "assembled.kdbx",
            credentialCandidate: KeePassCredentialCandidate(
                label: "password-only",
                password: password,
                keyMaterial: nil
            )
        )
    )
    let masterKey = try DefaultKeePassKdbxMasterKeyComposer().composeMasterKey(
        from: derivedKey,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs(
            masterSeed: masterSeed,
            encryptionIV: encryptionIV
        )
    )
    let encryptedPayload = try DefaultKeePassKdbxPayloadCipher().encryptPayload(
        xmlPayload,
        cipher: .aes256,
        masterKey: masterKey,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs(
            masterSeed: masterSeed,
            encryptionIV: encryptionIV
        )
    )
    let payloadSection = try DefaultKeePassKdbx4PayloadSectionWriter().writePayloadSection(
        encryptedPayloadBlocks: [encryptedPayload],
        headerBytes: header,
        masterSeed: masterSeed,
        derivedKey: derivedKey
    )

    let database = try DefaultKeePassKdbxFileAssembler().assemble(
        headerBytes: header,
        payloadSection: payloadSection
    )
    let envelope = try KeePassKdbxPayloadEnvelope.parse(database)
    let snapshot = try DefaultKeePassDatabaseReader().readSnapshot(
        database: database,
        sourceName: "assembled.kdbx",
        credentials: KeePassUnlockCredentials(password: password, keyFile: nil, keyFileName: nil)
    )

    #expect(envelope.headerBytes == header)
    #expect(envelope.encryptedPayload == payloadSection)
    #expect(snapshot.entries.first?.title == "Assembled Login")
    #expect(snapshot.entries.first?.username == "writer")
    #expect(snapshot.entries.first?.decodedPassword == "assembled password")
    #expect(!database.description.contains(password))
    #expect(!database.description.contains("assembled password"))
    #expect(!database.description.contains(xmlPayload.map { String(format: "%02x", $0) }.joined()))

    do {
        _ = try DefaultKeePassKdbxFileAssembler().assemble(
            headerBytes: Data("not-a-kdbx-header-secret".utf8),
            payloadSection: payloadSection
        )
        Issue.record("Expected invalid KDBX header to fail")
    } catch let error as KeePassOperationError {
        #expect(error.code == .formatUnsupported)
        #expect(!error.message.contains("not-a-kdbx-header-secret"))
        #expect(!error.message.contains("assembled password"))
    }
}

@Test func keepPassKdbx4HeaderWriterBuildsArgon2idHeaderForReadableWritebackWithoutLeakingSecrets() throws {
    let masterSeed = Data(repeating: 0x91, count: 32)
    let encryptionIV = Data(repeating: 0x92, count: 16)
    let argon2Salt = Data(repeating: 0x93, count: 32)
    let password = "header-writer-password-secret"
    let xmlPayload = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <KeePassFile>
      <Root>
        <Group>
          <UUID>header-writer-root</UUID>
          <Name>Header Writer Root</Name>
          <Entry>
            <UUID>header-writer-entry</UUID>
            <String><Key>Title</Key><Value>Header Writer Login</Value></String>
            <String><Key>UserName</Key><Value>argon2id</Value></String>
            <String><Key>Password</Key><Value>header writer decoded password</Value></String>
          </Entry>
        </Group>
      </Root>
    </KeePassFile>
    """.utf8)
    let header = try DefaultKeePassKdbx4HeaderWriter().writeHeader(
        cipher: .aes256,
        compression: .none,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs(
            masterSeed: masterSeed,
            encryptionIV: encryptionIV,
            innerRandomStreamKey: Data(repeating: 0x94, count: 32),
            innerRandomStreamID: 2
        ),
        kdfParameters: KeePassKdbxKdfParameters(
            algorithm: .argon2id,
            argon2: KeePassKdbxArgon2Parameters(
                salt: argon2Salt,
                iterations: 1,
                memoryBytes: 8 * 1024,
                parallelism: 1,
                version: 0x13
            )
        )
    )
    let envelope = try KeePassKdbxPayloadEnvelope.parse(header)
    let derivedKey = try DefaultKeePassKdbxKeyDeriver().deriveKey(
        from: try KeePassKdbxDecryptInputContext.build(
            database: header + Data("placeholder".utf8),
            sourceName: "header-writer.kdbx",
            credentialCandidate: KeePassCredentialCandidate(
                label: "password-only",
                password: password,
                keyMaterial: nil
            )
        )
    )
    let masterKey = try DefaultKeePassKdbxMasterKeyComposer().composeMasterKey(
        from: derivedKey,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs(
            masterSeed: masterSeed,
            encryptionIV: encryptionIV
        )
    )
    let encryptedPayload = try DefaultKeePassKdbxPayloadCipher().encryptPayload(
        xmlPayload,
        cipher: .aes256,
        masterKey: masterKey,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs(
            masterSeed: masterSeed,
            encryptionIV: encryptionIV
        )
    )
    let payloadSection = try DefaultKeePassKdbx4PayloadSectionWriter().writePayloadSection(
        encryptedPayloadBlocks: [encryptedPayload],
        headerBytes: header,
        masterSeed: masterSeed,
        derivedKey: derivedKey
    )
    let database = try DefaultKeePassKdbxFileAssembler().assemble(
        headerBytes: header,
        payloadSection: payloadSection
    )
    let snapshot = try DefaultKeePassDatabaseReader().readSnapshot(
        database: database,
        sourceName: "header-writer.kdbx",
        credentials: KeePassUnlockCredentials(password: password, keyFile: nil, keyFileName: nil)
    )

    #expect(envelope.headerSummary.formatVersion == .kdbx4)
    #expect(envelope.headerSummary.cryptoSummary?.cipher == .aes256)
    #expect(envelope.headerSummary.cryptoSummary?.compression == KeePassKdbxCompressionAlgorithm.none)
    #expect(envelope.headerSummary.cryptoSummary?.kdf == .argon2id)
    #expect(envelope.headerSummary.kdfParameters?.argon2?.memoryBytes == 8 * 1024)
    #expect(envelope.headerSummary.kdfParameters?.argon2?.iterations == 1)
    #expect(envelope.headerSummary.kdfParameters?.argon2?.parallelism == 1)
    #expect(snapshot.entries.first?.title == "Header Writer Login")
    #expect(snapshot.entries.first?.username == "argon2id")
    #expect(snapshot.entries.first?.decodedPassword == "header writer decoded password")
    #expect(!header.description.contains(password))
    #expect(!header.description.contains("header writer decoded password"))
    #expect(!header.description.contains(xmlPayload.map { String(format: "%02x", $0) }.joined()))
    #expect(!envelope.displaySummary.contains(argon2Salt.map { String(format: "%02x", $0) }.joined()))

    do {
        _ = try DefaultKeePassKdbx4HeaderWriter().writeHeader(
            cipher: .aes256,
            compression: .none,
            cryptoInputs: KeePassKdbxPayloadCryptoInputs(
                masterSeed: Data("short-master-seed-secret".utf8),
                encryptionIV: encryptionIV
            ),
            kdfParameters: KeePassKdbxKdfParameters(
                algorithm: .argon2id,
                argon2: KeePassKdbxArgon2Parameters(
                    salt: argon2Salt,
                    iterations: 1,
                    memoryBytes: 8 * 1024,
                    parallelism: 1,
                    version: 0x13
                )
            )
        )
        Issue.record("Expected invalid KDBX4 header crypto inputs to fail")
    } catch let error as KeePassOperationError {
        #expect(error.code == .formatUnsupported)
        #expect(!error.message.contains("short-master-seed-secret"))
        #expect(!error.message.contains(password))
        #expect(!error.message.contains(argon2Salt.map { String(format: "%02x", $0) }.joined()))
    }
}

@Test func keepPassKdbx4WritebackCoordinatorBuildsReadableDatabaseWithoutLeakingSecrets() throws {
    let password = "writeback-coordinator-password-secret"
    let snapshot = KeePassReadOnlySnapshot(
        sourceName: "coordinator-edited.kdbx",
        headerSummary: nil,
        groups: [
            KeePassReadOnlyGroup(id: "root-group-uuid", title: "Root", path: "/", depth: 0),
            KeePassReadOnlyGroup(id: "team-group-uuid", title: "Team", path: "/Team", depth: 1)
        ],
        entries: [
            KeePassReadOnlyEntry(
                id: "entry-coordinator-uuid",
                title: "Coordinator Login",
                username: "writer@example.com",
                url: "https://example.com/login",
                groupPath: "/Team",
                groupID: "team-group-uuid",
                notes: "coordinator edited notes secret",
                hasPassword: true,
                decodedPassword: "coordinator decoded password",
                hasTotp: false,
                attachmentCount: 0,
                isDeleted: false
            )
        ]
    )
    let request = KeePassKdbx4WritebackRequest(
        snapshot: snapshot,
        credentials: KeePassUnlockCredentials(password: password, keyFile: nil, keyFileName: nil),
        cipher: .aes256,
        compression: .gzip,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs(
            masterSeed: Data(repeating: 0xA1, count: 32),
            encryptionIV: Data(repeating: 0xA2, count: 16),
            innerRandomStreamKey: Data(repeating: 0xA3, count: 32),
            innerRandomStreamID: 2
        ),
        kdfParameters: KeePassKdbxKdfParameters(
            algorithm: .argon2id,
            argon2: KeePassKdbxArgon2Parameters(
                salt: Data(repeating: 0xA4, count: 32),
                iterations: 1,
                memoryBytes: 8 * 1024,
                parallelism: 1,
                version: 0x13
            )
        )
    )

    let result = try DefaultKeePassKdbx4WritebackCoordinator().writeDatabase(request)
    let envelope = try KeePassKdbxPayloadEnvelope.parse(result.database)
    let reparsed = try DefaultKeePassDatabaseReader().readSnapshot(
        database: result.database,
        sourceName: "coordinator-edited.kdbx",
        credentials: KeePassUnlockCredentials(password: password, keyFile: nil, keyFileName: nil)
    )

    #expect(result.displaySummary.contains("KDBX4 writeback"))
    #expect(result.displaySummary.contains("2 个分组"))
    #expect(result.displaySummary.contains("1 个条目"))
    #expect(envelope.headerSummary.cryptoSummary?.compression == .gzip)
    #expect(envelope.headerSummary.cryptoSummary?.kdf == .argon2id)
    #expect(reparsed.groups.map(\.path) == ["/", "/Team"])
    let entry = try #require(reparsed.entries.first)
    #expect(entry.title == "Coordinator Login")
    #expect(entry.username == "writer@example.com")
    #expect(entry.decodedPassword == "coordinator decoded password")
    #expect(entry.notes == "coordinator edited notes secret")
    #expect(!result.displaySummary.contains(password))
    #expect(!result.displaySummary.contains("coordinator decoded password"))
    #expect(!result.displaySummary.contains("coordinator edited notes secret"))
    #expect(!result.database.description.contains(password))
    #expect(!result.database.description.contains("coordinator decoded password"))
}

@Test func defaultKeePassPayloadDecryptorUnwrapsKdbx4HmacBlocksBeforeAesCipherWithoutLeakingSecrets() throws {
    final class FixedKeyDeriver: KeePassKdbxKeyDeriver, @unchecked Sendable {
        func deriveKey(from context: KeePassKdbxDecryptInputContext) throws -> KeePassKdbxDerivedKey {
            KeePassKdbxDerivedKey(
                algorithm: .aesKdf,
                material: Data(repeating: 0x11, count: 32),
                rounds: 1
            )
        }
    }

    final class FixedMasterKeyComposer: KeePassKdbxMasterKeyComposer, @unchecked Sendable {
        func composeMasterKey(
            from derivedKey: KeePassKdbxDerivedKey,
            cryptoInputs: KeePassKdbxPayloadCryptoInputs
        ) throws -> KeePassKdbxMasterKeyMaterial {
            KeePassKdbxMasterKeyMaterial(
                algorithm: derivedKey.algorithm,
                material: try decodeHexData("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
            )
        }
    }

    final class RecordingPayloadCipher: KeePassKdbxPayloadCipher, @unchecked Sendable {
        var calls: [(cipher: KeePassKdbxCipherAlgorithm, payload: Data)] = []

        func decryptPayload(
            _ encryptedPayload: Data,
            cipher: KeePassKdbxCipherAlgorithm,
            masterKey: KeePassKdbxMasterKeyMaterial,
            cryptoInputs: KeePassKdbxPayloadCryptoInputs
        ) throws -> Data {
            calls.append((cipher: cipher, payload: encryptedPayload))
            return Data("decrypted-block-stream-secret".utf8)
        }
    }

    let derivedMaterial = Data(repeating: 0x11, count: 32)
    let masterSeed = Data(repeating: 0xB5, count: 32)
    var baseKeyInput = Data()
    baseKeyInput.append(masterSeed)
    baseKeyInput.append(derivedMaterial)
    baseKeyInput.append(0x01)
    let hmacBaseKey = Data(SHA512.hash(data: baseKeyInput))
    let kdfParameters = KeePassKdbxKdfParameters(
        algorithm: .aesKdf,
        aesKdf: KeePassKdbxAesKdfParameters(seed: Data(repeating: 0xA5, count: 32), rounds: 1)
    )
    let encryptedPayload = Data("encrypted-payload-secret".utf8)
    let hmacBlockStream = makeKdbx4PayloadSection(
        hmacBaseKey: hmacBaseKey,
        blocks: [encryptedPayload]
    )
    let context = KeePassKdbxDecryptInputContext(
        sourceName: "aes-payload.kdbx",
        candidateLabel: "password-only",
        envelope: KeePassKdbxPayloadEnvelope(
            headerSummary: KeePassHeaderSummary(
                majorVersion: 4,
                minorVersion: 0,
                formatVersion: .kdbx4,
                cryptoSummary: KeePassKdbxCryptoSummary(
                    cipher: .aes256,
                    compression: .gzip,
                    kdf: .aesKdf
                ),
                kdfParameters: kdfParameters
            ),
            headerFields: [:],
            headerByteRange: 0..<0,
            encryptedPayload: hmacBlockStream
        ),
        kdfParameters: kdfParameters,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs(
            masterSeed: masterSeed,
            encryptionIV: Data(repeating: 0xC5, count: 16)
        ),
        credentialMaterial: KeePassKdbxCredentialMaterial(
            passwordKey: Data("password-key-secret".utf8),
            keyFileKey: nil,
            compositeKey: Data(SHA256.hash(data: Data("composite-key-secret".utf8)))
        )
    )
    let payloadCipher = RecordingPayloadCipher()
    let decryptor = DefaultKeePassKdbxPayloadDecryptor(
        keyDeriver: FixedKeyDeriver(),
        masterKeyComposer: FixedMasterKeyComposer(),
        payloadCipher: payloadCipher
    )

    let decodedPayload = try decryptor.decryptPayload(context)

    #expect(decodedPayload == Data("decrypted-block-stream-secret".utf8))
    #expect(payloadCipher.calls.count == 1)
    #expect(payloadCipher.calls.first?.cipher == .aes256)
    #expect(payloadCipher.calls.first?.payload == encryptedPayload)
}

@Test func defaultKeePassPayloadDecryptorSkipsKdbx4HeaderHashAndHmacBeforeBlocks() throws {
    final class FixedKeyDeriver: KeePassKdbxKeyDeriver, @unchecked Sendable {
        func deriveKey(from context: KeePassKdbxDecryptInputContext) throws -> KeePassKdbxDerivedKey {
            KeePassKdbxDerivedKey(
                algorithm: .aesKdf,
                material: Data(repeating: 0x22, count: 32),
                rounds: 1
            )
        }
    }

    final class FixedMasterKeyComposer: KeePassKdbxMasterKeyComposer, @unchecked Sendable {
        func composeMasterKey(
            from derivedKey: KeePassKdbxDerivedKey,
            cryptoInputs: KeePassKdbxPayloadCryptoInputs
        ) throws -> KeePassKdbxMasterKeyMaterial {
            KeePassKdbxMasterKeyMaterial(
                algorithm: derivedKey.algorithm,
                material: Data(repeating: 0x33, count: 32)
            )
        }
    }

    final class RecordingPayloadCipher: KeePassKdbxPayloadCipher, @unchecked Sendable {
        var payloads: [Data] = []

        func decryptPayload(
            _ encryptedPayload: Data,
            cipher: KeePassKdbxCipherAlgorithm,
            masterKey: KeePassKdbxMasterKeyMaterial,
            cryptoInputs: KeePassKdbxPayloadCryptoInputs
        ) throws -> Data {
            payloads.append(encryptedPayload)
            return Data("<KeePassFile />".utf8)
        }
    }

    let masterSeed = Data(repeating: 0x44, count: 32)
    let derivedMaterial = Data(repeating: 0x22, count: 32)
    var baseKeyInput = Data()
    baseKeyInput.append(masterSeed)
    baseKeyInput.append(derivedMaterial)
    baseKeyInput.append(0x01)
    let hmacBaseKey = Data(SHA512.hash(data: baseKeyInput))
    let encryptedPayload = Data("encrypted-kdbx4-payload-secret".utf8)
    let headerBytes = Data("header bytes".utf8)
    var kdbx4PayloadSection = Data(SHA256.hash(data: headerBytes))
    kdbx4PayloadSection.append(kdbx4HeaderHmac(headerBytes: headerBytes, hmacBaseKey: hmacBaseKey))
    kdbx4PayloadSection.append(makeKdbx4HmacBlockStream(hmacBaseKey: hmacBaseKey, blocks: [encryptedPayload]))
    let kdfParameters = KeePassKdbxKdfParameters(
        algorithm: .aesKdf,
        aesKdf: KeePassKdbxAesKdfParameters(seed: Data(repeating: 0xA5, count: 32), rounds: 1)
    )
    let context = KeePassKdbxDecryptInputContext(
        sourceName: "kdbx4-prelude.kdbx",
        candidateLabel: "password-only",
        envelope: KeePassKdbxPayloadEnvelope(
            headerSummary: KeePassHeaderSummary(
                majorVersion: 4,
                minorVersion: 0,
                formatVersion: .kdbx4,
                cryptoSummary: KeePassKdbxCryptoSummary(cipher: .aes256, compression: KeePassKdbxCompressionAlgorithm.none, kdf: .aesKdf),
                kdfParameters: kdfParameters
            ),
            headerFields: [:],
            headerBytes: headerBytes,
            headerByteRange: 0..<0,
            encryptedPayload: kdbx4PayloadSection
        ),
        kdfParameters: kdfParameters,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs(
            masterSeed: masterSeed,
            encryptionIV: Data(repeating: 0x66, count: 16)
        ),
        credentialMaterial: KeePassKdbxCredentialMaterial(
            passwordKey: Data("password-key-secret".utf8),
            keyFileKey: nil,
            compositeKey: Data(repeating: 0x77, count: 32)
        )
    )
    let payloadCipher = RecordingPayloadCipher()
    let decryptor = DefaultKeePassKdbxPayloadDecryptor(
        keyDeriver: FixedKeyDeriver(),
        masterKeyComposer: FixedMasterKeyComposer(),
        payloadCipher: payloadCipher
    )

    let decoded = try decryptor.decryptPayload(context)

    #expect(decoded == Data("<KeePassFile />".utf8))
    #expect(payloadCipher.payloads == [encryptedPayload])
}

@Test func defaultKeePassPayloadDecryptorDecodesKdbx3BlockStreamToXmlPayload() throws {
    final class FixedKeyDeriver: KeePassKdbxKeyDeriver, @unchecked Sendable {
        func deriveKey(from context: KeePassKdbxDecryptInputContext) throws -> KeePassKdbxDerivedKey {
            KeePassKdbxDerivedKey(
                algorithm: .aesKdf,
                material: Data(repeating: 0x11, count: 32),
                rounds: 1
            )
        }
    }

    final class FixedMasterKeyComposer: KeePassKdbxMasterKeyComposer, @unchecked Sendable {
        func composeMasterKey(
            from derivedKey: KeePassKdbxDerivedKey,
            cryptoInputs: KeePassKdbxPayloadCryptoInputs
        ) throws -> KeePassKdbxMasterKeyMaterial {
            KeePassKdbxMasterKeyMaterial(
                algorithm: derivedKey.algorithm,
                material: Data(repeating: 0x22, count: 32)
            )
        }
    }

    final class FixedPayloadCipher: KeePassKdbxPayloadCipher, @unchecked Sendable {
        let decryptedPayload: Data

        init(decryptedPayload: Data) {
            self.decryptedPayload = decryptedPayload
        }

        func decryptPayload(
            _ encryptedPayload: Data,
            cipher: KeePassKdbxCipherAlgorithm,
            masterKey: KeePassKdbxMasterKeyMaterial,
            cryptoInputs: KeePassKdbxPayloadCryptoInputs
        ) throws -> Data {
            decryptedPayload
        }
    }

    let streamStartBytes = Data(repeating: 0xA6, count: 32)
    let xmlPayload = Data("<KeePassFile><Root /></KeePassFile>".utf8)
    let decryptedBlockStream = makeKdbx3HashedBlockStream(
        streamStartBytes: streamStartBytes,
        blocks: [xmlPayload]
    )
    let kdfParameters = KeePassKdbxKdfParameters(
        algorithm: .aesKdf,
        aesKdf: KeePassKdbxAesKdfParameters(seed: Data(repeating: 0xA5, count: 32), rounds: 1)
    )
    let encryptedPayload = Data("encrypted-payload-secret".utf8)
    let context = KeePassKdbxDecryptInputContext(
        sourceName: "kdbx3.kdbx",
        candidateLabel: "password-only",
        envelope: KeePassKdbxPayloadEnvelope(
            headerSummary: KeePassHeaderSummary(
                majorVersion: 3,
                minorVersion: 1,
                formatVersion: .kdbx3,
                cryptoSummary: KeePassKdbxCryptoSummary(
                    cipher: .aes256,
                    compression: KeePassKdbxCompressionAlgorithm.none,
                    kdf: .aesKdf
                ),
                kdfParameters: kdfParameters
            ),
            headerFields: [:],
            headerByteRange: 0..<0,
            encryptedPayload: encryptedPayload
        ),
        kdfParameters: kdfParameters,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs(
            masterSeed: Data(repeating: 0xB5, count: 32),
            encryptionIV: Data(repeating: 0xC5, count: 16),
            streamStartBytes: streamStartBytes
        ),
        credentialMaterial: KeePassKdbxCredentialMaterial(
            passwordKey: Data("password-key-secret".utf8),
            keyFileKey: nil,
            compositeKey: Data(SHA256.hash(data: Data("composite-key-secret".utf8)))
        )
    )
    let decryptor = DefaultKeePassKdbxPayloadDecryptor(
        keyDeriver: FixedKeyDeriver(),
        masterKeyComposer: FixedMasterKeyComposer(),
        payloadCipher: FixedPayloadCipher(decryptedPayload: decryptedBlockStream)
    )

    let decrypted = try decryptor.decryptPayload(context)

    #expect(decrypted == xmlPayload)
}

@Test func keepPassUnlockPreflightRequiresCredentialsAndSummarizesInputs() throws {
    let kdbx4 = Data([
        0x03, 0xD9, 0xA2, 0x9A,
        0x67, 0xFB, 0x4B, 0xB5,
        0x00, 0x00, 0x04, 0x00
    ])

    let preview = KeePassFormatInspector.inspect(kdbx4, sourceName: "personal.kdbx")
    #expect(preview.headerSummary?.formatVersion == .kdbx4)
    #expect(preview.headerSummary?.displayName == "KDBX 4")

    let missing = KeePassFormatInspector.prepareUnlock(
        kdbx4,
        sourceName: "personal.kdbx",
        password: "   ",
        keyFile: nil,
        keyFileName: nil
    )
    #expect(missing.status == .requiresCredentials)
    #expect(missing.issue?.code == .invalidCredential)
    #expect(missing.issue?.message == "请输入数据库密码或选择密钥文件")

    let ready = KeePassFormatInspector.prepareUnlock(
        kdbx4,
        sourceName: "personal.kdbx",
        password: "database-password",
        keyFile: Data([0x01, 0x02, 0x03]),
        keyFileName: "../personal.key"
    )
    #expect(ready.status == .readyToUnlock)
    #expect(ready.headerSummary?.formatVersion == .kdbx4)
    #expect(ready.credentials.hasPassword)
    #expect(ready.credentials.hasKeyFile)
    #expect(ready.credentials.keyFileName == "personal.key")
    #expect(ready.credentials.keyFileCandidateCount > 0)
    #expect(ready.credentials.displayName == "密码 + 密钥文件（3 种 key 解析）")
    #expect(ready.issue == nil)
}

@Test func keepPassCredentialSupportBuildsAndroidCompatibleKeyFileCandidatesWithoutLeakingMaterial() throws {
    let rawKey = Data((1...32).map(UInt8.init))
    let xml = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <KeyFile><Key><Data>\(rawKey.base64EncodedString())</Data></Key></KeyFile>
    """.utf8)
    let hex = Data("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF".utf8)

    let xmlMaterials = KeePassKeyFileMaterial.buildVariants(from: xml)
    #expect(xmlMaterials.map(\.label).contains("xml-data"))
    #expect(xmlMaterials.map(\.label).contains("raw"))
    #expect(xmlMaterials.map(\.label).contains("sha256(raw)"))
    #expect(xmlMaterials.first { $0.label == "xml-data" }?.key == rawKey)

    let hexMaterials = KeePassKeyFileMaterial.buildVariants(from: hex)
    #expect(hexMaterials.first { $0.label == "hex-text" }?.key.count == 32)

    let keyOnlyCredentials = KeePassUnlockCredentials(
        password: "",
        keyFile: xml,
        keyFileName: "../personal.key"
    )
    let keyOnlyLabels = keyOnlyCredentials.credentialCandidates.map(\.label)
    #expect(keyOnlyLabels.contains("xml-data/key-only"))
    #expect(keyOnlyLabels.contains("xml-data/empty-password+key"))
    #expect(keyOnlyCredentials.summary.keyFileCandidateCount == keyOnlyLabels.count)
    #expect(keyOnlyCredentials.summary.keyFileName == "personal.key")
    #expect(!keyOnlyCredentials.summary.displayName.contains(rawKey.base64EncodedString()))

    let passwordAndKeyCredentials = KeePassUnlockCredentials(
        password: "database-password",
        keyFile: xml,
        keyFileName: "personal.key"
    )
    let passwordAndKeyLabels = passwordAndKeyCredentials.credentialCandidates.map(\.label)
    #expect(passwordAndKeyLabels.first == "password-only")
    #expect(passwordAndKeyLabels.contains("xml-data/password+key"))
    #expect(!passwordAndKeyLabels.contains("xml-data/key-only"))

    let message = KeePassCredentialSupport.invalidCredentialMessage(
        attemptedLabels: ["raw/password+key", "xml-data/password+key", "sha256(raw)/password+key"]
    )
    #expect(message.contains("已尝试"))
    #expect(message.contains("xml-data/password+key"))
    #expect(!message.contains("database-password"))
    #expect(!message.contains(rawKey.base64EncodedString()))
}

@Test func keePassCandidateTryingDatabaseReaderAttemptsCandidatesUntilSnapshotSucceedsWithoutLeakingSecrets() throws {
    final class AttemptRecordingReader: KeePassDatabaseReader, @unchecked Sendable {
        struct Request: Equatable {
            let label: String?
            let password: String
            let keyMaterial: Data?
        }

        var requests: [Request] = []
        var failuresBeforeSuccess = 1
        let snapshot = KeePassReadOnlySnapshot(
            sourceName: "personal.kdbx",
            headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
            groups: [],
            entries: [
                KeePassReadOnlyEntry(
                    id: "entry-1",
                    title: "GitHub",
                    username: "alice",
                    url: "https://github.com",
                    groupPath: "/",
                    hasPassword: true,
                    hasTotp: false,
                    attachmentCount: 0,
                    isDeleted: false
                )
            ]
        )

        func readSnapshot(
            database: Data,
            sourceName: String?,
            credentials: KeePassUnlockCredentials
        ) throws -> KeePassReadOnlySnapshot {
            requests.append(
                Request(
                    label: credentials.candidateLabel,
                    password: credentials.password,
                    keyMaterial: credentials.keyFile
                )
            )
            if requests.count <= failuresBeforeSuccess {
                throw KeePassOperationError(
                    code: .invalidCredential,
                    message: "invalid candidate"
                )
            }
            return snapshot
        }
    }

    let baseReader = AttemptRecordingReader()
    let reader = KeePassCandidateTryingDatabaseReader(baseReader: baseReader)
    let keyFile = Data("key-file-secret".utf8)

    let snapshot = try reader.readSnapshot(
        database: Data([0x03, 0xD9, 0xA2, 0x9A]),
        sourceName: "personal.kdbx",
        credentials: KeePassUnlockCredentials(
            password: "database-password",
            keyFile: keyFile,
            keyFileName: "personal.key"
        )
    )

    #expect(snapshot.entryCount == 1)
    #expect(baseReader.requests.map(\.label) == ["password-only", "raw/password+key"])
    #expect(baseReader.requests.map(\.password) == ["database-password", "database-password"])
    #expect(baseReader.requests.first?.keyMaterial == nil)
    #expect(baseReader.requests.last?.keyMaterial == keyFile)
}

@Test func keePassCandidateTryingDatabaseReaderSummarizesInvalidCandidatesWithoutLeakingSecrets() throws {
    final class AlwaysInvalidReader: KeePassDatabaseReader, @unchecked Sendable {
        var labels: [String] = []

        func readSnapshot(
            database: Data,
            sourceName: String?,
            credentials: KeePassUnlockCredentials
        ) throws -> KeePassReadOnlySnapshot {
            if let label = credentials.candidateLabel {
                labels.append(label)
            }
            throw KeePassOperationError(
                code: .invalidCredential,
                message: "bad password database-password key-file-secret"
            )
        }
    }

    let baseReader = AlwaysInvalidReader()
    let reader = KeePassCandidateTryingDatabaseReader(baseReader: baseReader)

    #expect(throws: KeePassOperationError.self) {
        _ = try reader.readSnapshot(
            database: Data([0x03, 0xD9, 0xA2, 0x9A]),
            sourceName: "personal.kdbx",
            credentials: KeePassUnlockCredentials(
                password: "database-password",
                keyFile: Data("key-file-secret".utf8),
                keyFileName: "personal.key"
            )
        )
    }
    #expect(baseReader.labels == ["password-only", "raw/password+key", "sha256(raw)/password+key"])

    do {
        _ = try reader.readSnapshot(
            database: Data([0x03, 0xD9, 0xA2, 0x9A]),
            sourceName: "personal.kdbx",
            credentials: KeePassUnlockCredentials(
                password: "database-password",
                keyFile: Data("key-file-secret".utf8),
                keyFileName: "personal.key"
            )
        )
    } catch let error as KeePassOperationError {
        #expect(error.code == .invalidCredential)
        #expect(error.message.contains("raw/password+key"))
        #expect(error.message.contains("sha256(raw)/password+key"))
        #expect(!error.message.contains("database-password"))
        #expect(!error.message.contains("key-file-secret"))
    }
}

@Test func keepPassDatabaseReaderBuildsReadOnlySnapshotAndKeepsCredentialsOutOfSummary() throws {
    struct RecordingReader: KeePassDatabaseReader {
        var snapshot: KeePassReadOnlySnapshot
        func readSnapshot(
            database: Data,
            sourceName: String?,
            credentials: KeePassUnlockCredentials
        ) throws -> KeePassReadOnlySnapshot {
            #expect(database.count == 12)
            #expect(sourceName == "personal.kdbx")
            #expect(credentials.hasPassword)
            #expect(credentials.hasKeyFile)
            return snapshot
        }
    }

    let snapshot = KeePassReadOnlySnapshot(
        sourceName: "personal.kdbx",
        headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
        groups: [
            KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
            KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1)
        ],
        entries: [
            KeePassReadOnlyEntry(
                id: "entry-1",
                title: "GitHub",
                username: "alice",
                url: "https://github.com",
                groupPath: "/Work",
                hasPassword: true,
                hasTotp: false,
                attachmentCount: 0,
                isDeleted: false
            )
        ]
    )
    let reader = RecordingReader(snapshot: snapshot)
    let credentials = KeePassUnlockCredentials(
        password: "database-password",
        keyFile: Data("key-file-secret".utf8),
        keyFileName: "personal.key"
    )

    let result = try reader.readSnapshot(
        database: Data([0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5, 0x00, 0x00, 0x04, 0x00]),
        sourceName: "personal.kdbx",
        credentials: credentials
    )

    #expect(result.groupCount == 2)
    #expect(result.entryCount == 1)
    #expect(result.displaySummary == "KDBX 4，2 个分组，1 个条目")
    #expect(!result.displaySummary.contains("database-password"))
    #expect(!result.displaySummary.contains("key-file-secret"))
}

@Test func keePassXMLReadOnlySnapshotReaderParsesGroupsEntriesFieldsTotpAndAttachments() throws {
    let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <KeePassFile>
      <Meta>
        <RecycleBinUUID>trash-group-uuid</RecycleBinUUID>
        <Binaries>
          <Binary ID="0">ZGVjb2RlZCBhdHRhY2htZW50IHNlY3JldA==</Binary>
        </Binaries>
      </Meta>
      <Root>
        <Group>
          <UUID>root-group-uuid</UUID>
          <Name>Root</Name>
          <Group>
            <UUID>work-group-uuid</UUID>
            <Name>Work</Name>
            <Entry>
              <UUID>entry-github-uuid</UUID>
              <String><Key>Title</Key><Value>GitHub</Value></String>
              <String><Key>UserName</Key><Value>alice</Value></String>
              <String><Key>Password</Key><Value Protected="True">decoded login password</Value></String>
              <String><Key>URL</Key><Value>https://github.com</Value></String>
              <String><Key>Notes</Key><Value>decoded notes secret</Value></String>
              <String><Key>otp</Key><Value>otpauth://totp/GitHub:alice@example.com?secret=JBSWY3DPEHPK3PXP&amp;issuer=GitHub&amp;period=45&amp;digits=8&amp;algorithm=SHA256</Value></String>
              <String><Key>Recovery Code</Key><Value Protected="True">decoded recovery code</Value></String>
              <Binary><Key>contract.txt</Key><Value Ref="0" /></Binary>
            </Entry>
          </Group>
          <Group>
            <UUID>trash-group-uuid</UUID>
            <Name>Recycle Bin</Name>
            <Entry>
              <UUID>entry-trash-uuid</UUID>
              <String><Key>Title</Key><Value>Deleted Login</Value></String>
              <String><Key>UserName</Key><Value>bob</Value></String>
              <String><Key>Password</Key><Value>deleted password</Value></String>
            </Entry>
          </Group>
        </Group>
      </Root>
    </KeePassFile>
    """
    let reader = KeePassXMLReadOnlySnapshotReader()

    let snapshot = try reader.readSnapshot(
        database: Data(xml.utf8),
        sourceName: "decrypted.xml",
        credentials: KeePassUnlockCredentials(password: "database-password", keyFile: nil, keyFileName: nil)
    )

    #expect(snapshot.groupCount == 3)
    #expect(snapshot.groups.map(\.path) == ["/", "/Work", "/Recycle Bin"])
    #expect(snapshot.entries.count == 2)

    let github = try #require(snapshot.entries.first { $0.id == "entry-github-uuid" })
    #expect(github.title == "GitHub")
    #expect(github.username == "alice")
    #expect(github.url == "https://github.com")
    #expect(github.groupPath == "/Work")
    #expect(github.groupID == "work-group-uuid")
    #expect(github.notes == "decoded notes secret")
    #expect(github.hasPassword)
    #expect(github.decodedPassword == "decoded login password")
    #expect(github.hasTotp)
    #expect(github.decodedTotp?.secret == "JBSWY3DPEHPK3PXP")
    #expect(github.decodedTotp?.issuer == "GitHub")
    #expect(github.decodedTotp?.accountName == "alice@example.com")
    #expect(github.decodedTotp?.period == 45)
    #expect(github.decodedTotp?.digits == 8)
    #expect(github.decodedTotp?.algorithm == "SHA256")
    #expect(github.customFields.map(\.title) == ["Recovery Code"])
    #expect(github.customFields.first?.value == "decoded recovery code")
    #expect(github.customFields.first?.isProtected == true)
    #expect(github.attachments.first?.fileName == "contract.txt")
    #expect(github.attachments.first?.decodedContent == Data("decoded attachment secret".utf8))

    let deleted = try #require(snapshot.entries.first { $0.id == "entry-trash-uuid" })
    #expect(deleted.groupPath == "/Recycle Bin")
    #expect(deleted.isDeleted)

    #expect(!snapshot.displaySummary.contains("database-password"))
    #expect(!snapshot.displaySummary.contains("decoded login password"))
    #expect(!snapshot.displaySummary.contains("decoded attachment secret"))
}

@Test func keePassXMLPayloadWriterSerializesSnapshotForWritebackWithoutLeakingSecretsInSummary() throws {
    let snapshot = KeePassReadOnlySnapshot(
        sourceName: "edited.kdbx",
        headerSummary: nil,
        groups: [
            KeePassReadOnlyGroup(id: "root-group-uuid", title: "Root", path: "/", depth: 0),
            KeePassReadOnlyGroup(id: "work-group-uuid", title: "Work", path: "/Work", depth: 1),
            KeePassReadOnlyGroup(id: "trash-group-uuid", title: "Recycle Bin", path: "/Recycle Bin", depth: 1)
        ],
        entries: [
            KeePassReadOnlyEntry(
                id: "entry-github-uuid",
                title: "GitHub & CI",
                username: "alice@example.com",
                url: "https://github.com/acme?token=redacted",
                groupPath: "/Work",
                groupID: "work-group-uuid",
                notes: "edited notes secret",
                customFields: [
                    KeePassReadOnlyCustomField(title: "Recovery Code", value: "edited recovery secret", isProtected: true, sortOrder: 0)
                ],
                hasPassword: true,
                decodedPassword: "edited login password",
                hasTotp: true,
                decodedTotp: KeePassReadOnlyTotpSecret(
                    secret: "JBSWY3DPEHPK3PXP",
                    issuer: "GitHub",
                    accountName: "alice@example.com",
                    period: 45,
                    digits: 8,
                    algorithm: "SHA256"
                ),
                attachmentCount: 1,
                isDeleted: false,
                attachments: [
                    KeePassReadOnlyAttachment(
                        id: "0",
                        fileName: "contract & terms.txt",
                        originalSize: 29,
                        contentHash: "sha256:secret",
                        decodedContent: Data("edited attachment secret".utf8)
                    )
                ]
            ),
            KeePassReadOnlyEntry(
                id: "entry-trash-uuid",
                title: "Deleted Login",
                username: "bob",
                url: "",
                groupPath: "/Recycle Bin",
                groupID: "trash-group-uuid",
                hasPassword: true,
                decodedPassword: "deleted password",
                hasTotp: false,
                decodedTotp: nil,
                attachmentCount: 1,
                isDeleted: true,
                attachments: [
                    KeePassReadOnlyAttachment(
                        id: "1",
                        fileName: "deleted.txt",
                        originalSize: 25,
                        contentHash: "sha256:deleted",
                        decodedContent: Data("deleted attachment secret".utf8)
                    )
                ]
            )
        ]
    )

    let writer = KeePassXMLPayloadWriter()
    let result = try writer.write(snapshot)

    #expect(result.displaySummary == "KeePass XML writeback payload，3 个分组，2 个条目，2 个附件")
    #expect(!result.displaySummary.contains("edited login password"))
    #expect(!result.displaySummary.contains("edited attachment secret"))
    #expect(!result.displaySummary.contains("JBSWY3DPEHPK3PXP"))

    let xml = try #require(String(data: result.xmlPayload, encoding: .utf8))
    #expect(xml.contains("<KeePassFile>"))
    #expect(xml.contains("<RecycleBinUUID>trash-group-uuid</RecycleBinUUID>"))
    #expect(xml.contains("GitHub &amp; CI"))
    #expect(xml.contains("contract &amp; terms.txt"))

    let reparsed = try KeePassXMLReadOnlySnapshotReader().readSnapshot(
        database: result.xmlPayload,
        sourceName: "writeback.xml",
        credentials: KeePassUnlockCredentials(password: "database-password", keyFile: nil, keyFileName: nil)
    )
    #expect(reparsed.groups.map(\.path) == ["/", "/Work", "/Recycle Bin"])
    let github = try #require(reparsed.entries.first { $0.id == "entry-github-uuid" })
    #expect(github.title == "GitHub & CI")
    #expect(github.username == "alice@example.com")
    #expect(github.decodedPassword == "edited login password")
    #expect(github.decodedTotp?.secret == "JBSWY3DPEHPK3PXP")
    #expect(github.customFields.first?.value == "edited recovery secret")
    #expect(github.attachments.first?.fileName == "contract & terms.txt")
    #expect(github.attachments.first?.decodedContent == Data("edited attachment secret".utf8))
    let deleted = try #require(reparsed.entries.first { $0.id == "entry-trash-uuid" })
    #expect(deleted.isDeleted)
    #expect(deleted.attachments.first?.fileName == "deleted.txt")
    #expect(deleted.attachments.first?.decodedContent == Data("deleted attachment secret".utf8))
}

@Test func defaultKeePassDatabaseReaderParsesXMLButKeepsEncryptedKdbxUnsupported() throws {
    let reader = DefaultKeePassDatabaseReader()
    let xml = Data("""
    <KeePassFile>
      <Root>
        <Group>
          <UUID>root</UUID>
          <Name>Root</Name>
          <Entry>
            <UUID>entry</UUID>
            <String><Key>Title</Key><Value>GitHub</Value></String>
          </Entry>
        </Group>
      </Root>
    </KeePassFile>
    """.utf8)

    let snapshot = try reader.readSnapshot(
        database: xml,
        sourceName: "decrypted.xml",
        credentials: KeePassUnlockCredentials(password: "database-password", keyFile: nil, keyFileName: nil)
    )

    #expect(snapshot.entryCount == 1)
    #expect(snapshot.entries.first?.title == "GitHub")

    let encryptedKdbxHeader = Data([
        0x03, 0xD9, 0xA2, 0x9A,
        0x67, 0xFB, 0x4B, 0xB5,
        0x00, 0x00, 0x04, 0x00
    ])
    #expect(throws: KeePassOperationError.self) {
        _ = try reader.readSnapshot(
            database: encryptedKdbxHeader,
            sourceName: "personal.kdbx",
            credentials: KeePassUnlockCredentials(
                password: "database-password",
                keyFile: Data("key-file-secret".utf8),
                keyFileName: "personal.key"
            )
        )
    }
}

@Test func defaultKeePassDatabaseReaderDecryptsKdbx3AesFixtureToSnapshotWithoutLeakingCredentials() throws {
    let password = "database-password"
    let transformSeed = Data(repeating: 0xA7, count: 32)
    let transformRounds: UInt64 = 1
    let masterSeed = Data(repeating: 0xB7, count: 32)
    let encryptionIV = Data(repeating: 0xC7, count: 16)
    let streamStartBytes = Data(repeating: 0xD7, count: 32)
    let innerStreamKey = Data(repeating: 0xE7, count: 32)
    _ = Data("""
    <KeePassFile>
      <Root>
        <Group>
          <UUID>root</UUID>
          <Name>Root</Name>
          <Entry>
            <UUID>entry-1</UUID>
            <String><Key>Title</Key><Value>GitHub</Value></String>
            <String><Key>UserName</Key><Value>alice</Value></String>
            <String><Key>Password</Key><Value>decoded-password-secret</Value></String>
            <String><Key>URL</Key><Value>https://github.com</Value></String>
          </Entry>
        </Group>
      </Root>
    </KeePassFile>
    """.utf8)
    let encryptedPayload = try decodeHexData("""
    8075e305ddb80b5ac7de98243658f9f76cd881bb398de499bbb71d3442002f59
    47ea644e3c6ca1cf122a1bd289572d38f7da89224b54affb2383aef588f60f85
    703e94ffe092aa740a4996be3654d5cb065cf9a4e3b98fee879d1eb9029c36f3
    452616bdf0363dcbd34728a410aba5355fec542fd3417d0586e635dec62ef1685
    0cc20f950c8ba81ce141f43a3e499d94f787cddc2c8f38f87710d8de465655
    87a1169d8faf52c0f388ff1fb6530a83f05a7add41a7bfd171ced08e58abc811
    32c165d4b577855bd48c210c2037d7832f74cd63f59c941eef2a85da35a08ae
    23e4d9e5ac59ba0fe0d6588422f99452419f1eb94a1df61c65e4764222fcc
    d6db211e173230d36eaa2d29fd87b18a03c37038ef592203f396a9c99cdf03
    94aaaa367d0f400bb9e0aee2ab38dc0f44be739b9635c70b3a13e9dbd812
    7245af91bbc9922511d5188a8464934a70f8661ad04e0600c7303a6fe6bc386
    34570b984f29bdb01df5830cdf4df3e86e20e8a2b69f1b30d9d307c323f9a
    1cbf9fbe872c68d081bf8eec2f3a2c6362486bed18f1c21521eefdaebbd8a
    069c1f07a70c4cf6953e8b68e613ec20ad8d5c4588a1f5d153ad130f2ba3e
    5f2c626e8ac56148853af76bd7078b953d99bb05dc1571a78ff1b616efc7a1a
    1f54736ea9a4749496734f8e52918aea1ee2755f741e3ccb28f8114073fbff
    33074d3c4fef597251e769a8e141c1cbac04c158f270c24061d519a0eebe24
    e4f67c44e8403acf3d59bf4da531fb5e8f9e86fa2d38d0380877b7193240a
    54e31c8ed8d979d880a30ef2bafbf
    """)
    let header = makeKdbx3Header(
        cipherID: Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]),
        compressionFlags: Data([0x00, 0x00, 0x00, 0x00]),
        masterSeed: masterSeed,
        transformSeed: transformSeed,
        transformRounds: transformRounds,
        encryptionIV: encryptionIV,
        protectedStreamKey: innerStreamKey,
        streamStartBytes: streamStartBytes,
        innerRandomStreamID: 2
    )
    let database = header + encryptedPayload
    let reader = DefaultKeePassDatabaseReader()

    let snapshot = try reader.readSnapshot(
        database: database,
        sourceName: "kdbx3-aes-fixture.kdbx",
        credentials: KeePassUnlockCredentials(password: password, keyFile: nil, keyFileName: nil)
    )

    #expect(snapshot.headerSummary?.formatVersion == KeePassKdbxFormatVersion.kdbx3)
    #expect(snapshot.headerSummary?.kdfParameters?.aesKdf?.rounds == transformRounds)
    #expect(snapshot.entries.first?.title == "GitHub")
    #expect(snapshot.entries.first?.username == "alice")
    #expect(snapshot.entries.first?.decodedPassword == "decoded-password-secret")
    #expect(!snapshot.displaySummary.contains(password))
    #expect(!snapshot.displaySummary.contains("decoded-password-secret"))
    #expect(!snapshot.displaySummary.contains(transformSeed.map { String(format: "%02x", $0) }.joined()))
}

@Test func defaultKeePassDatabaseReaderDecodesKdbx3Salsa20ProtectedValuesWithoutLeakingSecrets() throws {
    let password = "protected-password"
    let transformSeed = Data(repeating: 0xA9, count: 32)
    let transformRounds: UInt64 = 1
    let masterSeed = Data(repeating: 0xB9, count: 32)
    let encryptionIV = Data(repeating: 0xC9, count: 16)
    let streamStartBytes = Data(repeating: 0xD9, count: 32)
    let protectedStreamKey = Data(repeating: 0xE9, count: 32)
    let protectedPasswordCiphertext = "Nk08LiY1j5itPBUT7sl27fU2M+aPV08BLQE="
    let encryptedPayload = try decodeHexData("""
    3edb
    6f5e0829dec4c71f6eafb1dd6722921c0df258ee1f2f904cd9b2626d79ee4123
    05901f080fc792100f0942647e95ad3d3a9aca17b931c3728e55d3a493aaea57
    49d6233377bae4a98322330d0a85af22a5b3f41f266215847de2b283fa36e722
    b0d406fbd2d90aae44c07708718ad99b9db863b0612deefd1c3ff1c2d3d92eb7
    de2b7ded1a161dc2aada3a197fa51421eefc61406cfc87e280c386df16c5d43f
    55c712d662fa61e8ccacfe628d4d3443e5de34938e43820f30ce189d5b5e0ac1
    28c274467e9f4511aabb923fd748973d89ddd01a772aeeeb65537bbeb837e371
    db90cf1894fd1ef7a4d0b951c7e5bbc1464def08d4b63cc3eb3d850144133214
    f4d3ffa4d490be70dfd99b084082ce88f5a64b191a761a2e0bd5b97c756b1c85
    0007422ac6d256c4bc0aa652c6bccae023e6c43fc8dae7b44e60cb748e11a760
    ac1b077b4b8da0d03ccb5050bea691a4619623b4d18e9a91a2d9e7e1b22256f1
    6c0c7d359ac6b7a4be89a110f0da383ec3aed31b3e379c29cedc2d95a91df871
    685dfdfffc4cee272bce046084b960b3b8196a445021b3ddc04bc3352fcba2d5
    0529a54589f4a5b9db03101f68357dd6f2e887e927bfcd4049007a007da66c51
    49f725aa9f4b76b963be86f226cab1077ba2283713b8d2ac19dadb5598048ee3
    2573c5ad72dd68c68544139443bf8b6f4da5a49cf1e2ee02a4c1979665bca521
    6c48a7016ff70186e4abd694e569a5f16af2f334d592603e13f7976f8831a4fd
    e8dd617cae4db848f310343058ceaaa60b3aa07c40857c9bb1b517295a992193
    e90d297ce7e45fcf4002e858e8f4f44028703e424766ce328518dd5e1aaff361
    c589e2ef6f93a286758074426b62
    """)
    let header = makeKdbx3Header(
        cipherID: Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]),
        compressionFlags: Data([0x00, 0x00, 0x00, 0x00]),
        masterSeed: masterSeed,
        transformSeed: transformSeed,
        transformRounds: transformRounds,
        encryptionIV: encryptionIV,
        protectedStreamKey: protectedStreamKey,
        streamStartBytes: streamStartBytes,
        innerRandomStreamID: 2
    )
    let database = header + encryptedPayload
    let reader = DefaultKeePassDatabaseReader()

    let snapshot = try reader.readSnapshot(
        database: database,
        sourceName: "kdbx3-salsa20-protected-values.kdbx",
        credentials: KeePassUnlockCredentials(password: password, keyFile: nil, keyFileName: nil)
    )

    let entry = try #require(snapshot.entries.first)
    #expect(snapshot.headerSummary?.formatVersion == KeePassKdbxFormatVersion.kdbx3)
    #expect(entry.title == "Protected GitHub")
    #expect(entry.username == "dana")
    #expect(entry.decodedPassword == "protected decoded password")
    #expect(!snapshot.displaySummary.contains(password))
    #expect(!snapshot.displaySummary.contains("protected decoded password"))
    #expect(!snapshot.displaySummary.contains(protectedPasswordCiphertext))
    #expect(!snapshot.displaySummary.contains(transformSeed.map { String(format: "%02x", $0) }.joined()))
}

@Test func defaultKeePassDatabaseReaderDecryptsKdbx4AesKdfFixtureToSnapshotWithoutLeakingCredentials() throws {
    let password = "kdbx4-password"
    let transformSeed = Data(repeating: 0xA8, count: 32)
    let database = try decodeHexData("""
    03d9a29a67fb4bb500000400021000000031c1f2e6bf714350be5805216afc5a
    ff0304000000000000000420000000b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8
    b8b8b8b8b8b8b8b8b8b8b8b8b8b8b80710000000c8c8c8c8c8c8c8c8c8c8c8c8
    c8c8c8c80820000000e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8e8
    e8e8e8e8e8e8e8e8e80a04000000020000000b5d000000000142050000002455
    55494410000000c9d9f39a628a4460bf740d08c18a4fea420100000053200000
    00a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8a8
    a80501000000520800000001000000000000000000040000000d0a0d0a383132
    aec311270c99adeb45e12b7d5296ee28b8fcc48cbff580e0f613b08ef1106afc
    ce868dae0046e8702102c46c9c0bd4905c90de572aed245987cce77b3559acb5
    f22fa19f5d22b9dbcbf2db0041461263e13524707813c46d5261971c36e00100
    001626009f52b603b527ef921d4a6ba775d1e5a6d30f9763c6834e48312e3881
    463f545749ac9ddb1745e667d8c310bb5f1a7a76d91a8ddf8cac80b89f4571ef
    f906e38ac464cdce600d6ade36addb95f4feeb4c623ef255a80553cdd205e595
    b5a0b79c8b0ea8f27462645b6c5ba29603f34d4d95b8c582f5e95a0ed3bdb662
    44859ff25015cc1fe034cff67c9bbcc35b898f5a57a166c96b726f210713af26
    c7e225e7b424c63f61922675a7d321f9bb62d741bb2028b7e3758e1bf07d6868
    dc1d9f1a1b263cfd172da036aa3e368b9685e05974e9ef926bed7fefdd78813e
    da15b8f0704b2aa0a286aeaab2fedd933cbc1be846bad768b6d4bfc16f0b4b86
    2cfc7b91848286138bbb768409c93c0ac4d5bfdd46890d57bde57e95784813ac
    b5a95e601aa2d5725776b002d83c602988733cbf808a39e2c7486673eb9b4684
    d00db60ec7872ea482f40dfcc95f11a5bd29f98391b2279f86ee3bd87eb6f4f7
    eba2c0807c6d38525256d66ad468573b6d5ef767be395e06061f8d23d7fab085
    191f678ab771050739d096fbd39f69bfd9192f57b4d81a97804a0dc4f7737d19
    8172739585dee2c1b0d0a20a334eb3d4cf69226894945fce3dfc9311a64267b8
    201dd4b43f86f10a528a790857d3a92dd7cc8742aa4ea56129a1856f66f28a41
    346df892a3db913e58fa8c6dbd4934189d8377f4b8786fdc6e01561a9c443988
    7200000000
    """)
    let reader = DefaultKeePassDatabaseReader()

    let snapshot = try reader.readSnapshot(
        database: database,
        sourceName: "kdbx4-aes-kdf-fixture.kdbx",
        credentials: KeePassUnlockCredentials(password: password, keyFile: nil, keyFileName: nil)
    )

    #expect(snapshot.headerSummary?.formatVersion == KeePassKdbxFormatVersion.kdbx4)
    #expect(snapshot.headerSummary?.kdfParameters?.aesKdf?.rounds == 1)
    #expect(snapshot.entries.first?.title == "KDBX4 GitLab")
    #expect(snapshot.entries.first?.username == "carol")
    #expect(snapshot.entries.first?.decodedPassword == "kdbx4-decoded-secret")
    #expect(!snapshot.displaySummary.contains(password))
    #expect(!snapshot.displaySummary.contains("kdbx4-decoded-secret"))
    #expect(!snapshot.displaySummary.contains(transformSeed.map { String(format: "%02x", $0) }.joined()))
}

@Test func defaultKeePassDatabaseReaderDecryptsKdbx4Argon2idFixtureToSnapshotWithoutLeakingCredentials() throws {
    let password = "argon2id-password"
    let salt = Data(repeating: 0xD2, count: 32)
    let masterSeed = Data(repeating: 0xB2, count: 32)
    let derivedKey = try decodeHexData("578c9c4377533e23dbacd1f01ae517ffcffec77d717ec4a7d5fd64eb72585192")
    let header = makeKdbx4Header(
        cipherID: Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]),
        compressionFlags: Data([0x00, 0x00, 0x00, 0x00]),
        masterSeed: masterSeed,
        encryptionIV: Data(repeating: 0xC2, count: 16),
        innerRandomStreamKey: Data(repeating: 0xE2, count: 64),
        innerRandomStreamID: 3,
        kdfParameters: makeKdbxVariantDictionary(entries: [
            kdbxVariantByteArray(key: "$UUID", value: Data([0x9E, 0x29, 0x8B, 0x19, 0x56, 0xDB, 0x47, 0x73, 0xB2, 0x3D, 0xFC, 0x3E, 0xC6, 0xF0, 0xA1, 0xE6])),
            kdbxVariantByteArray(key: "S", value: salt),
            kdbxVariantUInt64(key: "M", value: 1_048_576),
            kdbxVariantUInt64(key: "I", value: 2),
            kdbxVariantUInt32(key: "P", value: 1),
            kdbxVariantUInt32(key: "V", value: 0x13)
        ])
    )
    var hmacBaseInput = Data()
    hmacBaseInput.append(masterSeed)
    hmacBaseInput.append(derivedKey)
    hmacBaseInput.append(0x01)
    let hmacBaseKey = Data(SHA512.hash(data: hmacBaseInput))
    let encryptedPayload = try decodeHexData("""
    3d2a1e875deb7bcfe3c2f2b8d56b83b8520504667a60133ee1e65289bc4b98c39655
    83fcd00213ec87d6d4b58237abed08a90899be444285c638738b77989e740134cddb
    c777b16731e560e4eb738e25cf59505e5b8cde4b151ec821240e5dd98e78cbd812b7
    9f36169d26b350ca8a7ffeee94fded11a3c2d00fa57bfd7fa645fa68eb12498f017d
    f41cec10e0c567a9a01f3eee4f41d03cd831233f4fcda60bbfdadbad9ff12af949ec
    69bed55451243aa0e408c1089dff041aeac2dcebac74cc153ba0f510e53dcbd7cda2
    04d0a007b19518d7758baed85f335780136fc48821125f167e94b22356930d3d1946
    defbdf561cb96360afcf1ce6915cd91c58eee0a9b9cf2c3acd90a66b4e64e71e730f
    e28ea88432c5f5f697f61360dc9fd1313dfc4a09063d1dd1b5d80dcf37af0389d889
    cc0fc35114f0567e403af231e8f93723cf833002fe26f3ed9b84b0c8cad36e541527
    edfffb01f37c54114cd7d5876390d8627dfb89b323d6a5c373a7abfc7c6ee40f56d3
    10e4a298eee8b9db3509619068e373edde19779c195ed753994d677103136683ad54
    e88df054588b76d79d680d29e191ac319a13df043d0e62918f0e12efdc323db2ec20
    0a074816a98a4f5b0ee23518b04422d3fcfbfc60f3b35912ae2b65bebd4d695ca95c
    199f3f7d892f0d92670063e377d24e7a7201183bc7d306269614b5346f37f2ce33e6
    3faf7f51f63a635fadfce38dd157492a2ce58dd20c2d2ef0da68547aaf1d2c90237c
    3c22f3a66fe5debf8d7e6168f09b129f8e65fdc4a9e63a59003b3582339fd55bbb88
    5b5f1c5d0c80494f44d017330f1e312ede108318cc8ec91a54966afea9cd
    """)
    var payloadSection = Data(SHA256.hash(data: header))
    payloadSection.append(kdbx4HeaderHmac(headerBytes: header, hmacBaseKey: hmacBaseKey))
    payloadSection.append(makeKdbx4HmacBlockStream(hmacBaseKey: hmacBaseKey, blocks: [encryptedPayload]))
    let database = header + payloadSection
    let reader = DefaultKeePassDatabaseReader()

    let snapshot = try reader.readSnapshot(
        database: database,
        sourceName: "kdbx4-argon2id-fixture.kdbx",
        credentials: KeePassUnlockCredentials(password: password, keyFile: nil, keyFileName: nil)
    )

    let parameters = try #require(snapshot.headerSummary?.kdfParameters?.argon2)
    #expect(snapshot.headerSummary?.formatVersion == KeePassKdbxFormatVersion.kdbx4)
    #expect(snapshot.headerSummary?.kdfParameters?.algorithm == .argon2id)
    #expect(parameters.memoryBytes == 1_048_576)
    #expect(parameters.iterations == 2)
    #expect(parameters.parallelism == 1)
    #expect(parameters.version == 0x13)
    #expect(snapshot.entries.first?.title == "KDBX4 Argon2id")
    #expect(snapshot.entries.first?.username == "ivy")
    #expect(snapshot.entries.first?.decodedPassword == "argon2id-decoded-secret")
    #expect(!snapshot.displaySummary.contains(password))
    #expect(!snapshot.displaySummary.contains("argon2id-decoded-secret"))
    #expect(!snapshot.displaySummary.contains(salt.map { String(format: "%02x", $0) }.joined()))
}

@Test func defaultKeePassDatabaseReaderDecryptsKdbx4TwofishFixtureToSnapshotWithoutLeakingCredentials() throws {
    let password = "twofish-password"
    let transformSeed = Data(repeating: 0xAB, count: 32)
    let masterSeed = Data(repeating: 0xB3, count: 32)
    let derivedKey = try decodeHexData("1a882a2cc11e63af5aeddcfa9655bd8821f671fcca019df38f13a0005649615a")
    var hmacBaseInput = Data()
    hmacBaseInput.append(masterSeed)
    hmacBaseInput.append(derivedKey)
    hmacBaseInput.append(0x01)
    let hmacBaseKey = Data(SHA512.hash(data: hmacBaseInput))
    let header = makeKdbx4Header(
        cipherID: Data([0xAD, 0x68, 0xF2, 0x9F, 0x57, 0x6F, 0x4B, 0xB9, 0xA3, 0x6A, 0xD4, 0x7A, 0xF9, 0x65, 0x34, 0x6C]),
        compressionFlags: Data([0x00, 0x00, 0x00, 0x00]),
        masterSeed: masterSeed,
        encryptionIV: Data(repeating: 0xC3, count: 16),
        innerRandomStreamKey: Data(repeating: 0xE3, count: 32),
        innerRandomStreamID: 2,
        kdfParameters: makeKdbxVariantDictionary(entries: [
            kdbxVariantByteArray(key: "$UUID", value: Data([0xC9, 0xD9, 0xF3, 0x9A, 0x62, 0x8A, 0x44, 0x60, 0xBF, 0x74, 0x0D, 0x08, 0xC1, 0x8A, 0x4F, 0xEA])),
            kdbxVariantByteArray(key: "S", value: transformSeed),
            kdbxVariantUInt64(key: "R", value: 1)
        ])
    )
    let encryptedPayload = try decodeHexData("""
    20a3bf5908b20605f55a7a062ece8d446fa3527b0d61bb5f01b0e77bfa0fc98648b2
    be39f3538fbff00a3d6d94629f681421a1a9c4dfbfcff3237788cc7c458bfb4c9803
    9a5cf5193cd4cff63fe368e6c1dc5b942d41606a16fc9bc423ebb6a01704ad0a7b14
    4b41d41ae62c46b290c95d579546aca51840e77b2a18cffa92720e1f25915b635b30
    492aa2bf30682da826d47c6168ca95c04220b1beebe9db22712bbfff6136864d3ee4
    f36981ea1fbde08468377b34f08a59541ad6ffdbae77e728aac88c520cb8aabd0a87
    7dc1b620d6a9f5b0dd0ee079a487483a8d7d1540b47e824c878c569617cebfac74bc
    a06e3308e4f60c0dcdbf233854e12ea336d1aaf77f563a6b157c8e4f7926644739c8
    09bf66e1bc0c1aca48839db97ac782b03005ee65526b2da63f7802254cbe0cf188d3
    5d3331995baa1824a956b7c67be046b40fb501ada8f601282de444012ad25e061206
    16afc431ffef5d90388df4b7a04fb296aecd4eb9cacb2c612da60d62a75ee879a00e
    42837b6474bfba6bc4eb19760f37bfa25893fe4ab8c633e6e0e23cbbf62ef36babf4
    baf3297b1c60116a64441c9df01386c4f4aaf1bc089745198a532457f968fc8eb6d9
    11b3fdf41af9962d50be18fbba0b6967eaf1cbc37434
    """)
    var payloadSection = Data(SHA256.hash(data: header))
    payloadSection.append(kdbx4HeaderHmac(headerBytes: header, hmacBaseKey: hmacBaseKey))
    payloadSection.append(makeKdbx4HmacBlockStream(hmacBaseKey: hmacBaseKey, blocks: [encryptedPayload]))
    let database = header + payloadSection
    let reader = DefaultKeePassDatabaseReader()

    let snapshot = try reader.readSnapshot(
        database: database,
        sourceName: "kdbx4-twofish-fixture.kdbx",
        credentials: KeePassUnlockCredentials(password: password, keyFile: nil, keyFileName: nil)
    )

    #expect(snapshot.headerSummary?.formatVersion == KeePassKdbxFormatVersion.kdbx4)
    #expect(snapshot.headerSummary?.cryptoSummary?.cipher == .twofish)
    #expect(snapshot.headerSummary?.kdfParameters?.aesKdf?.rounds == 1)
    #expect(snapshot.entries.first?.title == "KDBX4 Twofish")
    #expect(snapshot.entries.first?.username == "jules")
    #expect(snapshot.entries.first?.decodedPassword == "twofish-decoded-secret")
    #expect(!snapshot.displaySummary.contains(password))
    #expect(!snapshot.displaySummary.contains("twofish-decoded-secret"))
    #expect(!snapshot.displaySummary.contains(transformSeed.map { String(format: "%02x", $0) }.joined()))
}

@Test func defaultKeePassDatabaseReaderDecryptsKdbx4AesKdfFixtureWithKeyFileCandidateWithoutLeakingCredentials() throws {
    let password = "keyfile-password"
    let rawKey = Data((1...32).map(UInt8.init))
    let xmlKeyFile = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <KeyFile><Key><Data>\(rawKey.base64EncodedString())</Data></Key></KeyFile>
    """.utf8)
    let transformSeed = Data(repeating: 0xAA, count: 32)
    let database = try decodeHexData("""
    03d9a29a67fb4bb500000400021000000031c1f2e6bf714350be5805216afc5a
    ff0304000000000000000420000000bababababababababababababababababa
    bababababababababababababababa0710000000cacacacacacacacacacacaca
    cacacaca0b5d00000000014205000000245555494410000000c9d9f39a628a44
    60bf740d08c18a4fea42010000005320000000aaaaaaaaaaaaaaaaaaaaaaaaaa
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa05010000005208000000010000
    00000000000000040000000d0a0d0a8cc106b7dd71fe5e4c87846f27e38f6cc4
    485ec2a75aa5e87e2ea1c808fa1674d5b001e33c945f8193aa2571a6c41d08d5
    bc0450d347f655b0aa5ef4083528cd3eeeb5dd228eff2e262d4eda9ac539a9e7
    5637c08390403712104f0fb446e4ee1002000050f4e96046647e1d1394672ea5
    211764338a0ed1ef301781917d4534fc4cf87c328aaa83bc37f105e398f9275d
    d5cc8b4554ff5d696729cd9c969bf95cac9b3e654a679b9d742229c90b008b28
    69ca6dea02de5a4e475b50a07e54d6bff3178bd2c068ce4e4e51d60bde15f892
    4346173f44f325b98f4e21c8c6ac28e64e421c6c53993fda9102bed6bc7ca76d
    5919046f1eb25e5565f5755c5c5123a142bd3914d14cbd71282d4a1ebfb552db
    5a0f4e3634a31e0870941830ea986d119c1e4df3e9268adba4b3d6f0934df65b
    9277c61297585ad230e0b5f8d73adaf3ea7da6d2de1b8d0cc22cbc50efd4fa1d
    7f719dbc26cca725efd3eba229a2a14c7507d239e65c51c09f57acf711135602
    72ed4a7acb064d7544c9cebeb67f39f062f3cae0ed161b257f95e9c02083c9a6
    7596265b2aa7b0d4c0b9072b61999bd4b56def5ff0d1a44991491576187a1aee
    bc171e2b225b9d53cb133b216342ef9f5596f48f3d7f90979175f89b3b2e5396
    1ab943b899ae0d433eb79c8058e86ba21d090824b79572f71c1608c81238dc97
    6c672ee922e578724b0b1816077fb8bb87d9c4da50fb3a3f36bc1763a9ded2ba
    3c40d33d0ef0a073ef50c0bc391c200797c0bcecd58599986a4a9cf9cacf485e
    4233c1737c147fbbc655f7d5b976e057e2a25f9227556e9fa08c7aa43b78d7b8
    0bc94d5a27787d00f612f389c1eacbcb6c9a6003aa93e1dc788ec3208ebb9e5d
    a82cea81729a384ffe5663b25c1a3aa0dcecada713f0d9e19380f54378b663ab
    6ccc9400000000
    """)
    let credentials = KeePassUnlockCredentials(
        password: password,
        keyFile: xmlKeyFile,
        keyFileName: "../personal.key"
    )
    #expect(credentials.credentialCandidates.map(\.label) == [
        "password-only",
        "raw/password+key",
        "xml-data/password+key",
        "sha256(raw)/password+key"
    ])
    let reader = KeePassCandidateTryingDatabaseReader(baseReader: DefaultKeePassDatabaseReader())

    let snapshot = try reader.readSnapshot(
        database: database,
        sourceName: "kdbx4-key-file-fixture.kdbx",
        credentials: credentials
    )

    #expect(snapshot.headerSummary?.formatVersion == KeePassKdbxFormatVersion.kdbx4)
    #expect(snapshot.headerSummary?.kdfParameters?.aesKdf?.rounds == 1)
    #expect(snapshot.entries.first?.title == "KDBX4 Key File")
    #expect(snapshot.entries.first?.username == "helen")
    #expect(snapshot.entries.first?.decodedPassword == "keyfile-decoded-secret")
    #expect(!snapshot.displaySummary.contains(password))
    #expect(!snapshot.displaySummary.contains(rawKey.base64EncodedString()))
    #expect(!snapshot.displaySummary.contains("keyfile-decoded-secret"))
    #expect(!snapshot.displaySummary.contains(transformSeed.map { String(format: "%02x", $0) }.joined()))
}

@Test func defaultKeePassDatabaseReaderDecodesKdbx4ChaCha20ProtectedValuesWithoutLeakingSecrets() throws {
    final class DecryptedXMLPayloadDecryptor: KeePassKdbxPayloadDecryptor, @unchecked Sendable {
        let decryptedPayload: Data
        var contexts: [KeePassKdbxDecryptInputContext] = []

        init(decryptedPayload: Data) {
            self.decryptedPayload = decryptedPayload
        }

        func decryptPayload(_ context: KeePassKdbxDecryptInputContext) throws -> Data {
            contexts.append(context)
            return decryptedPayload
        }
    }

    let password = "kdbx4-chacha-password"
    let innerRandomStreamKey = Data(repeating: 0xF4, count: 64)
    let protectedPasswordCiphertext = "Gtk2BHw0dbkr+efdBXh9A5YmgTn1nXVbzHy0vPDtbw=="
    let decodedPassword = "kdbx4 chacha protected password"
    let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <KeePassFile>
      <Root>
        <Group>
          <UUID>root-group-uuid</UUID>
          <Name>Root</Name>
          <Entry>
            <UUID>entry-chacha-uuid</UUID>
            <String><Key>Title</Key><Value>ChaCha Login</Value></String>
            <String><Key>UserName</Key><Value>erin</Value></String>
            <String><Key>Password</Key><Value Protected="True">\(protectedPasswordCiphertext)</Value></String>
          </Entry>
        </Group>
      </Root>
    </KeePassFile>
    """
    let header = makeKdbx4Header(
        cipherID: Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]),
        compressionFlags: Data([0x00, 0x00, 0x00, 0x00]),
        masterSeed: Data(repeating: 0xB4, count: 32),
        encryptionIV: Data(repeating: 0xC4, count: 16),
        innerRandomStreamKey: innerRandomStreamKey,
        innerRandomStreamID: 3,
        kdfParameters: makeKdbxVariantDictionary(entries: [
            kdbxVariantByteArray(key: "$UUID", value: Data([0xC9, 0xD9, 0xF3, 0x9A, 0x62, 0x8A, 0x44, 0x60, 0xBF, 0x74, 0x0D, 0x08, 0xC1, 0x8A, 0x4F, 0xEA])),
            kdbxVariantByteArray(key: "S", value: Data(repeating: 0xA4, count: 32)),
            kdbxVariantUInt64(key: "R", value: 1)
        ])
    )
    let decryptor = DecryptedXMLPayloadDecryptor(decryptedPayload: Data(xml.utf8))
    let reader = DefaultKeePassDatabaseReader(payloadDecryptor: decryptor)

    let snapshot = try reader.readSnapshot(
        database: header + Data("encrypted-payload-secret".utf8),
        sourceName: "kdbx4-chacha20-protected-values.kdbx",
        credentials: KeePassUnlockCredentials(password: password, keyFile: nil, keyFileName: nil)
    )

    let entry = try #require(snapshot.entries.first)
    let context = try #require(decryptor.contexts.first)
    #expect(snapshot.headerSummary?.formatVersion == KeePassKdbxFormatVersion.kdbx4)
    #expect(context.cryptoInputs.innerRandomStreamID == 3)
    #expect(context.cryptoInputs.innerRandomStreamKey == innerRandomStreamKey)
    #expect(entry.title == "ChaCha Login")
    #expect(entry.username == "erin")
    #expect(entry.decodedPassword == decodedPassword)
    #expect(!snapshot.displaySummary.contains(password))
    #expect(!snapshot.displaySummary.contains(decodedPassword))
    #expect(!snapshot.displaySummary.contains(protectedPasswordCiphertext))
    #expect(!snapshot.displaySummary.contains(innerRandomStreamKey.map { String(format: "%02x", $0) }.joined()))
}

@Test func defaultKeePassDatabaseReaderParsesKdbx4InnerHeaderBeforeProtectedValuesWithoutLeakingSecrets() throws {
    final class DecryptedPayloadWithInnerHeaderDecryptor: KeePassKdbxPayloadDecryptor, @unchecked Sendable {
        let decryptedPayload: Data

        init(decryptedPayload: Data) {
            self.decryptedPayload = decryptedPayload
        }

        func decryptPayload(_ context: KeePassKdbxDecryptInputContext) throws -> Data {
            decryptedPayload
        }
    }

    let password = "kdbx4-inner-header-password"
    let innerRandomStreamKey = Data(repeating: 0xF4, count: 64)
    let protectedPasswordCiphertext = "Gtk2BHw0dbkr+efdBXh9A5YmgTn1nXVbzHy0vPDtbw=="
    let decodedPassword = "kdbx4 chacha protected password"
    let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <KeePassFile>
      <Root>
        <Group>
          <UUID>root-group-uuid</UUID>
          <Name>Root</Name>
          <Entry>
            <UUID>entry-inner-header-uuid</UUID>
            <String><Key>Title</Key><Value>Inner Header Login</Value></String>
            <String><Key>UserName</Key><Value>finn</Value></String>
            <String><Key>Password</Key><Value Protected="True">\(protectedPasswordCiphertext)</Value></String>
          </Entry>
        </Group>
      </Root>
    </KeePassFile>
    """
    let header = makeKdbx4Header(
        cipherID: Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]),
        compressionFlags: Data([0x00, 0x00, 0x00, 0x00]),
        masterSeed: Data(repeating: 0xB6, count: 32),
        encryptionIV: Data(repeating: 0xC6, count: 16),
        kdfParameters: makeKdbxVariantDictionary(entries: [
            kdbxVariantByteArray(key: "$UUID", value: Data([0xC9, 0xD9, 0xF3, 0x9A, 0x62, 0x8A, 0x44, 0x60, 0xBF, 0x74, 0x0D, 0x08, 0xC1, 0x8A, 0x4F, 0xEA])),
            kdbxVariantByteArray(key: "S", value: Data(repeating: 0xA6, count: 32)),
            kdbxVariantUInt64(key: "R", value: 1)
        ])
    )
    let innerHeader = makeKdbx4InnerHeader(fields: [
        (1, littleEndianUInt32(3)),
        (2, innerRandomStreamKey)
    ])
    let decryptor = DecryptedPayloadWithInnerHeaderDecryptor(
        decryptedPayload: innerHeader + Data(xml.utf8)
    )
    let reader = DefaultKeePassDatabaseReader(payloadDecryptor: decryptor)

    let snapshot = try reader.readSnapshot(
        database: header + Data("encrypted-payload-secret".utf8),
        sourceName: "kdbx4-inner-header-protected-values.kdbx",
        credentials: KeePassUnlockCredentials(password: password, keyFile: nil, keyFileName: nil)
    )

    let entry = try #require(snapshot.entries.first)
    #expect(snapshot.headerSummary?.formatVersion == KeePassKdbxFormatVersion.kdbx4)
    #expect(entry.title == "Inner Header Login")
    #expect(entry.username == "finn")
    #expect(entry.decodedPassword == decodedPassword)
    #expect(!snapshot.displaySummary.contains(password))
    #expect(!snapshot.displaySummary.contains(decodedPassword))
    #expect(!snapshot.displaySummary.contains(protectedPasswordCiphertext))
    #expect(!snapshot.displaySummary.contains(innerRandomStreamKey.map { String(format: "%02x", $0) }.joined()))
}

@Test func defaultKeePassDatabaseReaderMergesKdbx4InnerHeaderBinariesIntoSnapshotWithoutLeakingSecrets() throws {
    final class DecryptedPayloadWithInnerHeaderDecryptor: KeePassKdbxPayloadDecryptor, @unchecked Sendable {
        let decryptedPayload: Data

        init(decryptedPayload: Data) {
            self.decryptedPayload = decryptedPayload
        }

        func decryptPayload(_ context: KeePassKdbxDecryptInputContext) throws -> Data {
            decryptedPayload
        }
    }

    let password = "kdbx4-inner-binary-password"
    let attachmentContent = Data("inner header attachment secret".utf8)
    let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <KeePassFile>
      <Root>
        <Group>
          <UUID>root-group-uuid</UUID>
          <Name>Root</Name>
          <Entry>
            <UUID>entry-inner-binary-uuid</UUID>
            <String><Key>Title</Key><Value>Inner Binary Login</Value></String>
            <String><Key>UserName</Key><Value>gwen</Value></String>
            <Binary><Key>inner.txt</Key><Value Ref="0" /></Binary>
          </Entry>
        </Group>
      </Root>
    </KeePassFile>
    """
    let header = makeKdbx4Header(
        cipherID: Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]),
        compressionFlags: Data([0x00, 0x00, 0x00, 0x00]),
        masterSeed: Data(repeating: 0xB7, count: 32),
        encryptionIV: Data(repeating: 0xC7, count: 16),
        kdfParameters: makeKdbxVariantDictionary(entries: [
            kdbxVariantByteArray(key: "$UUID", value: Data([0xC9, 0xD9, 0xF3, 0x9A, 0x62, 0x8A, 0x44, 0x60, 0xBF, 0x74, 0x0D, 0x08, 0xC1, 0x8A, 0x4F, 0xEA])),
            kdbxVariantByteArray(key: "S", value: Data(repeating: 0xA7, count: 32)),
            kdbxVariantUInt64(key: "R", value: 1)
        ])
    )
    let innerHeader = makeKdbx4InnerHeader(fields: [
        (3, Data([0x00]) + attachmentContent)
    ])
    let decryptor = DecryptedPayloadWithInnerHeaderDecryptor(
        decryptedPayload: innerHeader + Data(xml.utf8)
    )
    let reader = DefaultKeePassDatabaseReader(payloadDecryptor: decryptor)

    let snapshot = try reader.readSnapshot(
        database: header + Data("encrypted-payload-secret".utf8),
        sourceName: "kdbx4-inner-header-binary-attachments.kdbx",
        credentials: KeePassUnlockCredentials(password: password, keyFile: nil, keyFileName: nil)
    )

    let entry = try #require(snapshot.entries.first)
    let attachment = try #require(entry.attachments.first)
    let expectedAttachmentHash = Data(SHA256.hash(data: attachmentContent))
        .map { String(format: "%02x", $0) }
        .joined()
    #expect(snapshot.headerSummary?.formatVersion == KeePassKdbxFormatVersion.kdbx4)
    #expect(entry.title == "Inner Binary Login")
    #expect(entry.username == "gwen")
    #expect(attachment.fileName == "inner.txt")
    #expect(attachment.originalSize == Int64(attachmentContent.count))
    #expect(attachment.contentHash == "sha256:" + expectedAttachmentHash)
    #expect(attachment.decodedContent == attachmentContent)
    #expect(!snapshot.displaySummary.contains(password))
    #expect(!snapshot.displaySummary.contains("inner header attachment secret"))
    #expect(!snapshot.displaySummary.contains(attachmentContent.map { String(format: "%02x", $0) }.joined()))
}

@Test func defaultKeePassDatabaseReaderBuildsKdbxDecryptInputBeforeCryptoDecode() throws {
    final class RecordingDecryptor: KeePassKdbxPayloadDecryptor, @unchecked Sendable {
        var contexts: [KeePassKdbxDecryptInputContext] = []

        func decryptPayload(_ context: KeePassKdbxDecryptInputContext) throws -> Data {
            contexts.append(context)
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX crypto not implemented"
            )
        }
    }

    let salt = Data((0..<32).map(UInt8.init))
    let header = makeKdbx4Header(
        cipherID: Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]),
        compressionFlags: Data([0x01, 0x00, 0x00, 0x00]),
        kdfParameters: makeKdbxVariantDictionary(entries: [
            kdbxVariantByteArray(key: "$UUID", value: Data([0x9E, 0x29, 0x8B, 0x19, 0x56, 0xDB, 0x47, 0x73, 0xB2, 0x3D, 0xFC, 0x3E, 0xC6, 0xF0, 0xA1, 0xE6])),
            kdbxVariantByteArray(key: "S", value: salt),
            kdbxVariantUInt64(key: "I", value: 4),
            kdbxVariantUInt64(key: "M", value: 64 * 1024 * 1024),
            kdbxVariantUInt32(key: "P", value: 2),
            kdbxVariantUInt32(key: "V", value: 0x13)
        ])
    )
    let encryptedPayload = Data("encrypted-payload-bytes".utf8)
    let decryptor = RecordingDecryptor()
    let reader = DefaultKeePassDatabaseReader(payloadDecryptor: decryptor)

    #expect(throws: KeePassOperationError.self) {
        _ = try reader.readSnapshot(
            database: header + encryptedPayload,
            sourceName: "personal.kdbx",
            credentials: KeePassUnlockCredentials(
                password: "database-password",
                keyFile: Data("key-file-secret".utf8),
                keyFileName: "personal.key",
                candidateLabel: "raw/password+key"
            )
        )
    }

    let context = try #require(decryptor.contexts.first)
    #expect(context.sourceName == "personal.kdbx")
    #expect(context.candidateLabel == "raw/password+key")
    #expect(context.kdfParameters?.algorithm == .argon2id)
    #expect(context.envelope.encryptedPayload == encryptedPayload)
    #expect(context.credentialMaterial.componentSummary == "password + key file")
    #expect(context.displaySummary == "KDBX 4，payload 23 bytes，Argon2id，candidate raw/password+key，password + key file")
    #expect(!context.displaySummary.contains("database-password"))
    #expect(!context.displaySummary.contains("key-file-secret"))
    #expect(!context.displaySummary.contains(salt.map { String(format: "%02x", $0) }.joined()))
    #expect(!context.displaySummary.contains("encrypted-payload-bytes"))
}

@Test func unsupportedKeePassPayloadDecryptorDerivesKdfBeforePayloadDecodeWithoutLeakingSecrets() throws {
    final class RecordingKeyDeriver: KeePassKdbxKeyDeriver, @unchecked Sendable {
        var contexts: [KeePassKdbxDecryptInputContext] = []

        func deriveKey(from context: KeePassKdbxDecryptInputContext) throws -> KeePassKdbxDerivedKey {
            contexts.append(context)
            return KeePassKdbxDerivedKey(
                algorithm: .aesKdf,
                material: Data(SHA256.hash(data: Data("derived-key-secret".utf8))),
                rounds: 1
            )
        }
    }

    let kdfParameters = KeePassKdbxKdfParameters(
        algorithm: .aesKdf,
        aesKdf: KeePassKdbxAesKdfParameters(seed: Data(repeating: 0xA5, count: 32), rounds: 1)
    )
    let context = KeePassKdbxDecryptInputContext(
        sourceName: "aes-kdf.kdbx",
        candidateLabel: "raw/password+key",
        envelope: KeePassKdbxPayloadEnvelope(
            headerSummary: KeePassHeaderSummary(
                majorVersion: 4,
                minorVersion: 0,
                formatVersion: .kdbx4,
                cryptoSummary: KeePassKdbxCryptoSummary(
                    cipher: .aes256,
                    compression: .gzip,
                    kdf: .aesKdf
                ),
                kdfParameters: kdfParameters
            ),
            headerFields: [:],
            headerByteRange: 0..<0,
            encryptedPayload: Data(repeating: 0xD5, count: 16)
        ),
        kdfParameters: kdfParameters,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs(
            masterSeed: Data(repeating: 0xB5, count: 32),
            encryptionIV: Data(repeating: 0xC5, count: 16)
        ),
        credentialMaterial: KeePassKdbxCredentialMaterial(
            passwordKey: Data("password-key-secret".utf8),
            keyFileKey: Data("key-file-secret".utf8),
            compositeKey: Data(SHA256.hash(data: Data("composite-key-secret".utf8)))
        )
    )
    let keyDeriver = RecordingKeyDeriver()
    let decryptor = UnsupportedKeePassKdbxPayloadDecryptor(keyDeriver: keyDeriver)

    do {
        _ = try decryptor.decryptPayload(context)
        Issue.record("Expected payload decryptor to remain unsupported")
    } catch let error as KeePassOperationError {
        #expect(error.code == .formatUnsupported)
        #expect(error.message == "KDBX4 header authentication bytes 缺失；请确认文件未损坏。")
        #expect(!error.message.contains("derived-key-secret"))
        #expect(!error.message.contains("password-key-secret"))
        #expect(!error.message.contains("key-file-secret"))
        #expect(!error.message.contains("composite-key-secret"))
    }

    #expect(keyDeriver.contexts.map(\.candidateLabel) == ["raw/password+key"])
}

@Test func defaultKeePassDatabaseReaderInflatesGzipKeePassXMLWithoutLeakingCredentials() throws {
    let reader = DefaultKeePassDatabaseReader()
    let gzipXML = Data([
        31, 139, 8, 0, 234, 8, 31, 106, 0, 3, 77, 142, 77, 10, 194, 48,
        16, 133, 175, 226, 13, 230, 2, 143, 217, 248, 83, 165, 32, 82, 173, 251,
        136, 131, 4, 210, 166, 76, 38, 139, 222, 94, 155, 166, 224, 238, 227, 205,
        123, 195, 135, 86, 228, 230, 82, 58, 249, 32, 140, 46, 70, 99, 52, 26,
        243, 196, 232, 251, 203, 129, 245, 151, 128, 10, 226, 234, 6, 225, 174, 4,
        5, 113, 28, 77, 231, 90, 148, 133, 183, 230, 221, 212, 143, 31, 70, 43,
        51, 63, 188, 5, 1, 45, 136, 167, 11, 89, 120, 31, 135, 73, 37, 37,
        121, 239, 26, 111, 231, 252, 2, 173, 7, 208, 54, 164, 250, 154, 170, 11,
        173, 102, 244, 111, 251, 5, 154, 180, 44, 88, 187, 0, 0, 0
    ])

    let snapshot = try reader.readSnapshot(
        database: gzipXML,
        sourceName: "decrypted-kdbx-payload.xml.gz",
        credentials: KeePassUnlockCredentials(
            password: "database-password",
            keyFile: Data("key-file-secret".utf8),
            keyFileName: "personal.key"
        )
    )

    #expect(snapshot.entryCount == 1)
    #expect(snapshot.entries.first?.title == "Compressed GitHub")
    #expect(!snapshot.displaySummary.contains("database-password"))
    #expect(!snapshot.displaySummary.contains("key-file-secret"))
}

@Test func keepPassReadOnlyImportPlannerBuildsPreviewOnlyPlanWithoutLeakingSecrets() throws {
    let snapshot = KeePassReadOnlySnapshot(
        sourceName: "personal.kdbx",
        headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
        groups: [
            KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
            KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1)
        ],
        entries: [
            KeePassReadOnlyEntry(
                id: "entry-1",
                title: "GitHub",
                username: "alice",
                url: "https://github.com",
                groupPath: "/Work",
                groupID: "group-uuid-work",
                hasPassword: true,
                decodedPassword: "decoded-login-password",
                hasTotp: true,
                decodedTotp: KeePassReadOnlyTotpSecret(
                    secret: "JBSWY3DPEHPK3PXP",
                    issuer: "GitHub",
                    accountName: "alice@example.com",
                    period: 30,
                    digits: 6,
                    algorithm: "SHA1"
                ),
                attachmentCount: 2,
                isDeleted: false,
                attachments: [
                    KeePassReadOnlyAttachment(
                        id: "attachment-uuid-contract",
                        fileName: "contract.pdf",
                        mediaType: "application/pdf",
                        originalSize: 2048,
                        contentHash: "sha256:contract"
                    ),
                    KeePassReadOnlyAttachment(
                        id: "attachment-uuid-notes",
                        fileName: "notes.txt",
                        mediaType: "text/plain",
                        originalSize: 512,
                        contentHash: "sha256:notes"
                    )
                ]
            ),
            KeePassReadOnlyEntry(
                id: "entry-2",
                title: "Deleted",
                username: "bob",
                url: "https://deleted.example",
                groupPath: "/Trash",
                groupID: "group-uuid-trash",
                hasPassword: true,
                hasTotp: false,
                attachmentCount: 0,
                isDeleted: true
            )
        ]
    )

    let plan = KeePassReadOnlyImportPlanner.plan(snapshot)

    #expect(plan.candidateCount == 2)
    #expect(plan.deletedCandidateCount == 1)
    #expect(plan.skippedCount == 0)
    #expect(plan.candidates.first?.title == "GitHub")
    #expect(plan.candidates.first?.kind == .login)
    #expect(plan.candidates.first?.groupPath == "/Work")
    #expect(plan.candidates.first?.groupID == "group-uuid-work")
    #expect(plan.candidates.first?.hasPassword == true)
    #expect(plan.candidates.first?.decodedPassword == "decoded-login-password")
    #expect(plan.candidates.first?.decodedTotp?.secret == "JBSWY3DPEHPK3PXP")
    #expect(plan.candidates.first?.decodedTotp?.issuer == "GitHub")
    #expect(plan.candidates.first?.decodedTotp?.accountName == "alice@example.com")
    #expect(plan.candidates.first?.isDeleted == false)
    #expect(plan.candidates.first?.attachments.map(\.fileName) == ["contract.pdf", "notes.txt"])
    #expect(plan.candidates.first?.attachments.map(\.contentHash) == ["sha256:contract", "sha256:notes"])
    #expect(plan.candidates.last?.title == "Deleted")
    #expect(plan.candidates.last?.username == "bob")
    #expect(plan.candidates.last?.url == "https://deleted.example")
    #expect(plan.candidates.last?.groupID == "group-uuid-trash")
    #expect(plan.candidates.last?.isDeleted == true)
    #expect(plan.pendingPasswordCount == 1)
    #expect(plan.pendingTotpCount == 0)
    #expect(plan.pendingAttachmentCount == 2)
    #expect(plan.pendingCapabilitySummary == "待解码：1 个密码字段，2 个附件")
    #expect(plan.displaySummary == "KDBX 4，2 个可预览条目，0 个跳过")
    #expect(!plan.displaySummary.contains("group-uuid-work"))
    #expect(!plan.displaySummary.contains("group-uuid-trash"))
    #expect(!plan.pendingCapabilitySummary.contains("database-password"))
    #expect(!plan.pendingCapabilitySummary.contains("key-file-secret"))
    #expect(!plan.pendingCapabilitySummary.contains("decoded-login-password"))
    #expect(!plan.pendingCapabilitySummary.contains("JBSWY3DPEHPK3PXP"))
    #expect(!plan.displaySummary.contains("database-password"))
    #expect(!plan.displaySummary.contains("key-file-secret"))
    #expect(!plan.displaySummary.contains("decoded-login-password"))
    #expect(!plan.displaySummary.contains("JBSWY3DPEHPK3PXP"))
}

@Test func keepPassReadOnlyImportPlannerCarriesDecodedSecretsWithoutCountingThemPending() throws {
    let snapshot = KeePassReadOnlySnapshot(
        sourceName: "personal.kdbx",
        headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
        groups: [
            KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
            KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1)
        ],
        entries: [
            KeePassReadOnlyEntry(
                id: "entry-decoded",
                title: "GitHub",
                username: "alice",
                url: "https://github.com",
                groupPath: "/Work",
                groupID: "group-uuid-work",
                hasPassword: true,
                decodedPassword: "decoded-password-secret",
                hasTotp: true,
                decodedTotp: KeePassReadOnlyTotpSecret(secret: "JBSWY3DPEHPK3PXP"),
                attachmentCount: 1,
                isDeleted: false
            ),
            KeePassReadOnlyEntry(
                id: "entry-pending",
                title: "Bank",
                username: "alice",
                url: "https://bank.example",
                groupPath: "/Work",
                groupID: "group-uuid-work",
                hasPassword: true,
                hasTotp: true,
                attachmentCount: 0,
                isDeleted: false
            )
        ]
    )

    let plan = KeePassReadOnlyImportPlanner.plan(snapshot)

    #expect(plan.candidates.first?.decodedPassword == "decoded-password-secret")
    #expect(plan.candidates.first?.decodedTotp?.secret == "JBSWY3DPEHPK3PXP")
    #expect(plan.pendingPasswordCount == 1)
    #expect(plan.pendingTotpCount == 1)
    #expect(plan.pendingAttachmentCount == 1)
    #expect(plan.pendingCapabilitySummary == "待解码：1 个密码字段，1 个 TOTP，1 个附件")
    #expect(!plan.displaySummary.contains("decoded-password-secret"))
    #expect(!plan.pendingCapabilitySummary.contains("decoded-password-secret"))
    #expect(!plan.displaySummary.contains("JBSWY3DPEHPK3PXP"))
    #expect(!plan.pendingCapabilitySummary.contains("JBSWY3DPEHPK3PXP"))
}

@Test func keepPassReadOnlyImportPlannerCarriesDecodedAttachmentContentWithoutCountingItPending() throws {
    let decodedContent = Data("decoded attachment bytes".utf8)
    let snapshot = KeePassReadOnlySnapshot(
        sourceName: "personal.kdbx",
        headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
        groups: [
            KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
            KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1)
        ],
        entries: [
            KeePassReadOnlyEntry(
                id: "entry-decoded-attachment",
                title: "GitHub",
                username: "alice",
                url: "https://github.com",
                groupPath: "/Work",
                groupID: "group-uuid-work",
                hasPassword: false,
                hasTotp: false,
                attachmentCount: 2,
                isDeleted: false,
                attachments: [
                    KeePassReadOnlyAttachment(
                        id: "attachment-decoded",
                        fileName: "contract.pdf",
                        mediaType: "application/pdf",
                        originalSize: Int64(decodedContent.count),
                        contentHash: "sha256:decoded",
                        decodedContent: decodedContent
                    ),
                    KeePassReadOnlyAttachment(
                        id: "attachment-pending",
                        fileName: "pending.txt",
                        mediaType: "text/plain",
                        originalSize: 128,
                        contentHash: "sha256:pending"
                    )
                ]
            )
        ]
    )

    let plan = KeePassReadOnlyImportPlanner.plan(snapshot)

    #expect(plan.candidates.first?.attachments.first?.decodedContent == decodedContent)
    #expect(plan.pendingAttachmentCount == 1)
    #expect(plan.pendingCapabilitySummary == "待解码：1 个附件")
    #expect(!plan.displaySummary.contains("decoded attachment bytes"))
    #expect(!plan.pendingCapabilitySummary.contains("decoded attachment bytes"))
}

@Test func keepPassReadOnlyImportPlannerCarriesNotesAndCustomFieldsWithoutLeakingValues() throws {
    let snapshot = KeePassReadOnlySnapshot(
        sourceName: "personal.kdbx",
        headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
        groups: [
            KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
            KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1)
        ],
        entries: [
            KeePassReadOnlyEntry(
                id: "entry-fields",
                title: "GitHub",
                username: "alice",
                url: "https://github.com",
                groupPath: "/Work",
                groupID: "group-uuid-work",
                notes: "decoded KeePass notes secret",
                customFields: [
                    KeePassReadOnlyCustomField(
                        title: "Recovery Code",
                        value: "decoded recovery code secret",
                        isProtected: true,
                        sortOrder: 2
                    ),
                    KeePassReadOnlyCustomField(
                        title: "Environment",
                        value: "Production",
                        isProtected: false,
                        sortOrder: 1
                    )
                ],
                hasPassword: false,
                hasTotp: false,
                attachmentCount: 0,
                isDeleted: false
            )
        ]
    )

    let plan = KeePassReadOnlyImportPlanner.plan(snapshot)

    #expect(plan.candidates.first?.notes == "decoded KeePass notes secret")
    #expect(plan.candidates.first?.customFields.map(\.title) == ["Environment", "Recovery Code"])
    #expect(plan.candidates.first?.customFields.first?.value == "Production")
    #expect(plan.candidates.first?.customFields.last?.isProtected == true)
    #expect(!plan.displaySummary.contains("decoded KeePass notes secret"))
    #expect(!plan.displaySummary.contains("decoded recovery code secret"))
    #expect(!plan.pendingCapabilitySummary.contains("decoded KeePass notes secret"))
    #expect(!plan.pendingCapabilitySummary.contains("decoded recovery code secret"))
}

@Test func unifiedVaultItemNormalizesCoreAndroidParityTypes() {
    let login = UnifiedVaultItem(
        id: "login-1",
        source: .mdbx,
        kind: .login,
        title: "GitHub",
        subtitle: "alice",
        searchableText: "GitHub alice github.com",
        isFavorite: true,
        isDeleted: false
    )
    let card = UnifiedVaultItem(
        id: "card-1",
        source: .mdbx,
        kind: .card,
        title: "Everyday Visa",
        subtitle: "Visa / **** 1111",
        searchableText: "Everyday Visa Monica Bank",
        isFavorite: false,
        isDeleted: false
    )

    #expect(UnifiedVaultItemKind.phaseOneKinds == [.login, .totp, .note, .card, .identity])
    #expect(login.listTitle == "GitHub")
    #expect(login.listSubtitle == "alice")
    #expect(login.matches("github"))
    #expect(login.matches("ALICE"))
    #expect(!login.matches("apple"))
    #expect(card.kind.displayName == "银行卡")
}

@Test func unifiedVaultItemKindsExposeFullAndroidParitySurface() {
    #expect(UnifiedVaultItemKind.fullAndroidParityKinds == [
        .login,
        .card,
        .identity,
        .totp,
        .passkey,
        .note,
        .sshKey,
        .apiToken,
        .wifi,
        .send,
        .attachmentRef
    ])
    #expect(UnifiedVaultItemKind.passkey.displayName == "通行密钥")
    #expect(UnifiedVaultItemKind.sshKey.displayName == "SSH 密钥")
    #expect(UnifiedVaultItemKind.apiToken.displayName == "API Token")
    #expect(UnifiedVaultItemKind.wifi.displayName == "Wi-Fi")
    #expect(UnifiedVaultItemKind.send.displayName == "安全发送")
    #expect(UnifiedVaultItemKind.attachmentRef.displayName == "附件")
}

@Test func androidParityDraftTypesCarrySensitiveFieldsInsidePayloadModels() {
    let passkey = LocalPasskeyEntryDraft(
        title: "GitHub passkey",
        relyingPartyID: "github.com",
        username: "alice",
        userHandle: "user-handle",
        credentialID: "credential-id",
        publicKeyCOSE: "public-key",
        privateKeyReference: "keychain-ref",
        notes: "synced metadata"
    )
    let sshKey = LocalSshKeyEntryDraft(
        title: "Production deploy",
        username: "deploy",
        host: "prod.example.com",
        publicKey: "ssh-ed25519 AAAA...",
        privateKeyReference: "keychain-ref",
        passphraseHint: "stored in vault payload",
        notes: "rotate quarterly"
    )
    let apiToken = LocalApiTokenEntryDraft(
        title: "OpenAI",
        issuer: "OpenAI",
        accountName: "alice@example.com",
        token: "sk-secret",
        scopes: "responses.read",
        expiresAt: "2026-12-31",
        notes: "agent denied by default"
    )
    let wifi = LocalWifiEntryDraft(
        title: "Studio Wi-Fi",
        ssid: "MonicaLab",
        securityType: "WPA2",
        password: "wifi-secret",
        hidden: false,
        notes: "office network"
    )
    let send = LocalSendEntryDraft(
        title: "One-time secret",
        body: "share this once",
        expiresAt: "2026-06-02T00:00:00Z",
        maxViews: 1,
        notes: "local-first metadata"
    )
    let attachment = LocalAttachmentMetadata(
        id: "attachment-1",
        projectID: "project-1",
        entryID: "entry-1",
        fileName: "photo.png",
        mediaType: "image/png",
        originalSize: 128,
        storedSize: 96,
        contentHash: "sha256:test",
        storageMode: "embedded-inline",
        deleted: false
    )

    #expect(passkey.relyingPartyID == "github.com")
    #expect(sshKey.privateKeyReference == "keychain-ref")
    #expect(apiToken.token == "sk-secret")
    #expect(wifi.hidden == false)
    #expect(send.maxViews == 1)
    #expect(attachment.storageMode == "embedded-inline")
}

@Test func localWifiEntriesExposeStandardQRCodePayload() {
    let secured = LocalWifiEntry(
        id: "wifi-1",
        projectID: "project-1",
        title: "Studio",
        ssid: "Monica;Lab",
        securityType: "WPA3",
        password: #"pa:ss\word"#,
        hidden: true,
        notes: ""
    )
    let open = LocalWifiEntry(
        id: "wifi-2",
        projectID: "project-1",
        title: "Guest",
        ssid: "Guest, Network",
        securityType: "open",
        password: "",
        hidden: false,
        notes: ""
    )

    #expect(secured.qrCodePayload == #"WIFI:T:WPA;S:Monica\;Lab;P:pa\:ss\\word;H:true;;"#)
    #expect(open.qrCodePayload == #"WIFI:T:nopass;S:Guest\, Network;H:false;;"#)
}

@Test func csvMigrationCodecImportsCoreAndExtendedVaultItems() {
    let csv = #"""
    kind,title,username,password,url,body,secret,issuer,accountName,period,digits,algorithm,otpType,counter,cardholderName,number,expiryMonth,expiryYear,cvv,network,documentType,fullName,documentNumber,country,issueDate,expiryDate,relyingPartyID,userHandle,credentialID,publicKeyCOSE,privateKeyReference,host,publicKey,passphraseHint,token,scopes,expiresAt,ssid,securityType,hidden,maxViews,notes
    login,GitHub,alice,"p,ass","https://github.com",,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,
    note,"Launch, Notes",,,,"Line 1
    Line 2",,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,"quoted ""note"""
    totp,GitHub 2FA,,,,,JBSWY3DPEHPK3PXP,GitHub,alice,30,6,SHA1,totp,0,,,,,,,,,,,,,,,,,,,,,,,,,
    card,Everyday Visa,,,,,,,,,,,,,Alice,4111111111111111,12,2030,123,Visa,,,,,,,,,,,,,,,,,,Monica Bank card
    identity,Passport,,,,,,,,,,,,,,,,,,,,Passport,Alice Example,P1234567,US,2024-01-01,2034-01-01,,,,,,,,,,,,,
    passkey,GitHub passkey,alice,,,,,,,,,,,,,,,,,,,,,,,,github.com,user-handle,credential-id,public-key-cose,keychain://passkeys/github,,,,,,,,,
    sshKey,Production deploy,deploy,,,,,,,,,,,,,,,,,,,,,,,,,,,,keychain://ssh/prod,prod.example.com,ssh-ed25519 AAAA,hardware key,,,,,,rotate quarterly
    apiToken,OpenAI,,, ,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,sk-secret,responses.read,2027-01-01,,,,,agent token
    wifi,Studio Wi-Fi,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,MonicaLab,WPA3,true,,office network
    send,One-time send,,,,share once,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,2026-06-02,,,1,share once only
    """#

    let report = VaultCSVCodec.importItems(from: csv)

    #expect(report.issues.isEmpty)
    #expect(report.items.count == 10)
    #expect(report.items.map(\.kind) == [.login, .note, .totp, .card, .identity, .passkey, .sshKey, .apiToken, .wifi, .send])

    guard case .login(let login) = report.items[0] else {
        Issue.record("Expected login draft")
        return
    }
    #expect(login.password == "p,ass")
    #expect(login.url == "https://github.com")

    guard case .note(let note) = report.items[1] else {
        Issue.record("Expected note draft")
        return
    }
    #expect(note.body == "Line 1\nLine 2")

    guard case .totp(let totp) = report.items[2] else {
        Issue.record("Expected totp draft")
        return
    }
    #expect(totp.secret == "JBSWY3DPEHPK3PXP")
    #expect(totp.period == 30)
    #expect(totp.digits == 6)

    guard case .wifi(let wifi) = report.items[8] else {
        Issue.record("Expected Wi-Fi draft")
        return
    }
    #expect(wifi.hidden)
    #expect(wifi.password == "")

    guard case .send(let send) = report.items[9] else {
        Issue.record("Expected send draft")
        return
    }
    #expect(send.maxViews == 1)
}

@Test func csvMigrationCodecExportsEscapedHeaderAndRoundTripsSensitiveFields() {
    let items: [VaultCSVItemDraft] = [
        .login(LocalLoginEntryDraft(title: "GitHub", username: "alice", password: "p,ass", url: "https://github.com")),
        .note(LocalNoteEntryDraft(title: "Launch", body: "Line 1\nLine 2")),
        .apiToken(LocalApiTokenEntryDraft(title: "OpenAI", issuer: "OpenAI", accountName: "alice@example.com", token: "sk-secret", scopes: "responses.read", expiresAt: "2027-01-01", notes: "quoted \"note\""))
    ]

    let csv = VaultCSVCodec.exportItems(items)
    let report = VaultCSVCodec.importItems(from: csv)

    #expect(csv.hasPrefix(VaultCSVCodec.headerLine))
    #expect(csv.contains("\"p,ass\""))
    #expect(csv.contains("\"Line 1\nLine 2\""))
    #expect(csv.contains("\"quoted \"\"note\"\"\""))
    #expect(report.issues.isEmpty)
    #expect(report.items == items)
}

@Test func csvMigrationCodecReportsValidationIssuesWithoutLeakingSensitiveValues() {
    let csv = #"""
    kind,title,username,password,secret,token,period,digits,maxViews,hidden
    login,,alice,super-secret-password,,,,,,
    totp,Broken 2FA,,,JBSWY3DPEHPK3PXP,,not-number,also-bad,,
    apiToken,Unknown,,,,sk-live-secret,,,,
    wifi,Studio,,,,,,,not-a-number,not-bool
    mystery,Secret Thing,,hidden-password,,sk-hidden,,,,
    """#

    let report = VaultCSVCodec.importItems(from: csv)
    let issueText = report.issues.map(\.message).joined(separator: "\n")

    #expect(report.items.count == 1)
    #expect(report.issues.map(\.code).contains(.missingRequiredField))
    #expect(report.issues.map(\.code).contains(.invalidNumber))
    #expect(report.issues.map(\.code).contains(.invalidBoolean))
    #expect(report.issues.map(\.code).contains(.unsupportedKind))
    #expect(!issueText.contains("super-secret-password"))
    #expect(!issueText.contains("JBSWY3DPEHPK3PXP"))
    #expect(!issueText.contains("sk-live-secret"))
    #expect(!issueText.contains("hidden-password"))
    #expect(!issueText.contains("sk-hidden"))
}

@Test func androidBackupCodecImportsCurrentZipFolderLayout() throws {
    let entries: [String: String] = [
        "folders/Work/passwords/password_1_1000.json": #"{"id":1,"title":"GitHub","username":"alice","password":"p,ass","website":"https://github.com","isFavorite":true,"authenticatorKey":"JBSWY3DPEHPK3PXP","categoryName":"Work"}"#,
        "folders/Work/authenticators/totp_2_1000.json": #"{"id":2,"title":"GitHub 2FA","itemData":"{\"secret\":\"JBSWY3DPEHPK3PXP\",\"issuer\":\"GitHub\",\"accountName\":\"alice\",\"period\":30,\"digits\":6,\"algorithm\":\"SHA1\",\"otpType\":\"TOTP\",\"counter\":0}","notes":"primary","categoryName":"Work"}"#,
        "folders/Personal/notes/note_3_1000.json": #"{"id":3,"title":"Recovery","itemData":"backup codes","notes":"note fallback","categoryName":"Personal"}"#,
        "folders/Finance/bank_cards/bank_card_4_1000.json": #"{"id":4,"itemType":"BANK_CARD","title":"Everyday Visa","itemData":"{\"cardNumber\":\"4111111111111111\",\"cardholderName\":\"Alice Example\",\"expiryMonth\":\"12\",\"expiryYear\":\"2031\",\"cvv\":\"123\",\"bankName\":\"Monica Bank\",\"brand\":\"Visa\"}","notes":"main card","categoryName":"Finance"}"#,
        "folders/Personal/documents/document_5_1000.json": #"{"id":5,"itemType":"DOCUMENT","title":"Passport","itemData":"{\"documentType\":\"PASSPORT\",\"documentNumber\":\"P1234567\",\"fullName\":\"Alice Example\",\"issuedDate\":\"2024-01-01\",\"expiryDate\":\"2034-01-01\",\"issuedBy\":\"Monica Authority\",\"country\":\"US\"}","notes":"travel","categoryName":"Personal"}"#,
        "folders/Work/passkeys/passkey_credential-id.json": #"{"credentialId":"credential-id","rpId":"github.com","rpName":"GitHub","userId":"user-handle","userName":"alice","userDisplayName":"Alice Example","publicKey":"public-key-cose","privateKeyAlias":"keychain://passkeys/github","notes":"synced metadata","categoryName":"Work"}"#
    ]
    let backup = try AndroidBackupCodec.exportZip(entries: entries)

    let report = try AndroidBackupCodec.importItems(from: backup)

    #expect(report.issues.isEmpty)
    #expect(report.items.map(\.kind) == [.login, .totp, .note, .card, .identity, .passkey])
    #expect(report.importedItems.map(\.sourceID) == [1, 2, 3, 4, 5, nil])

    guard case .login(let login) = report.items[0] else {
        Issue.record("Expected login")
        return
    }
    #expect(login.title == "GitHub")
    #expect(login.username == "alice")
    #expect(login.password == "p,ass")
    #expect(login.url == "https://github.com")

    guard case .totp(let totp) = report.items[1] else {
        Issue.record("Expected TOTP")
        return
    }
    #expect(totp.secret == "JBSWY3DPEHPK3PXP")
    #expect(totp.issuer == "GitHub")
    #expect(totp.accountName == "alice")

    guard case .note(let note) = report.items[2] else {
        Issue.record("Expected note")
        return
    }
    #expect(note.body == "backup codes")

    guard case .card(let card) = report.items[3] else {
        Issue.record("Expected card")
        return
    }
    #expect(card.cardholderName == "Alice Example")
    #expect(card.number == "4111111111111111")
    #expect(card.issuer == "Monica Bank")
    #expect(card.network == "Visa")

    guard case .identity(let identity) = report.items[4] else {
        Issue.record("Expected identity")
        return
    }
    #expect(identity.documentType == "PASSPORT")
    #expect(identity.documentNumber == "P1234567")
    #expect(identity.issuer == "Monica Authority")

    guard case .passkey(let passkey) = report.items[5] else {
        Issue.record("Expected passkey")
        return
    }
    #expect(passkey.relyingPartyID == "github.com")
    #expect(passkey.username == "alice")
    #expect(passkey.credentialID == "credential-id")
}

@Test func androidBackupCodecExportsAndroidFolderLayoutAndRoundTrips() throws {
    let items: [VaultCSVItemDraft] = [
        .login(LocalLoginEntryDraft(title: "GitHub", username: "alice", password: "p,ass", url: "https://github.com")),
        .note(LocalNoteEntryDraft(title: "Recovery", body: "backup codes")),
        .totp(LocalTotpEntryDraft(title: "GitHub 2FA", secret: "JBSWY3DPEHPK3PXP", issuer: "GitHub", accountName: "alice", period: 30, digits: 6, algorithm: "SHA1", otpType: "TOTP", counter: 0)),
        .card(LocalCardEntryDraft(title: "Everyday Visa", cardholderName: "Alice Example", number: "4111111111111111", expiryMonth: "12", expiryYear: "2031", cvv: "123", issuer: "Monica Bank", network: "Visa", notes: "main card")),
        .identity(LocalIdentityEntryDraft(title: "Passport", documentType: "PASSPORT", fullName: "Alice Example", documentNumber: "P1234567", issuer: "Monica Authority", country: "US", issueDate: "2024-01-01", expiryDate: "2034-01-01", notes: "travel"))
    ]

    let backup = try AndroidBackupCodec.exportItems(items)
    let entries = try AndroidBackupCodec.inspectEntryNames(in: backup)
    let report = try AndroidBackupCodec.importItems(from: backup)

    #expect(entries.contains { $0.hasPrefix("folders/Imported/passwords/password_") })
    #expect(entries.contains { $0.hasPrefix("folders/Imported/authenticators/totp_") })
    #expect(entries.contains { $0.hasPrefix("folders/Imported/notes/note_") })
    #expect(entries.contains { $0.hasPrefix("folders/Imported/bank_cards/bank_card_") })
    #expect(entries.contains { $0.hasPrefix("folders/Imported/documents/document_") })
    #expect(report.issues.isEmpty)
    #expect(report.items == items)
}

@Test func androidBackupCodecImportsLegacyZipCsvFallbackEntries() throws {
    let passwordCSV = """
    \u{FEFF}name,url,username,password,note,email,phone,custom_fields
    GitHub,https://github.com,alice,"p,ass","primary login

    [MonicaMeta]isFavorite=true|createdAt=1710000000000|updatedAt=1710000000000",alice@example.com,+15551234567,
    """
    let totpCSV = """
    ID,Type,Title,Data,Notes,IsFavorite,ImagePaths,CreatedAt,UpdatedAt
    10,TOTP,GitHub 2FA,"{""secret"":""JBSWY3DPEHPK3PXP"",""issuer"":""GitHub"",""accountName"":""alice"",""period"":30,""digits"":6,""algorithm"":""SHA1"",""otpType"":""TOTP"",""counter"":0}",primary,false,,1710000000000,1710000000000
    """
    let cardsDocsCSV = """
    ID,Type,Title,Data,Notes,IsFavorite,ImagePaths,CreatedAt,UpdatedAt
    11,BANK_CARD,Everyday Visa,"{""cardNumber"":""4111111111111111"",""cardholderName"":""Alice Example"",""expiryMonth"":""12"",""expiryYear"":""2031"",""cvv"":""123"",""bankName"":""Monica Bank"",""brand"":""Visa""}",main card,false,,1710000000000,1710000000000
    12,DOCUMENT,Passport,"{""documentType"":""PASSPORT"",""documentNumber"":""P1234567"",""fullName"":""Alice Example"",""issuedDate"":""2024-01-01"",""expiryDate"":""2034-01-01"",""issuedBy"":""Monica Authority"",""country"":""US""}",travel,false,,1710000000000,1710000000000
    """
    let notesCSV = """
    ID,Type,Title,Data,Notes,IsFavorite,ImagePaths,CreatedAt,UpdatedAt
    13,NOTE,Recovery,backup codes,legacy note,false,,1710000000000,1710000000000
    """
    let backup = try AndroidBackupCodec.exportZip(entries: [
        "Monica_20260601_120000_password.csv": passwordCSV,
        "Monica_20260601_120000_totp.csv": totpCSV,
        "Monica_20260601_120000_cards_docs.csv": cardsDocsCSV,
        "Monica_20260601_120000_notes.csv": notesCSV
    ])

    let report = try AndroidBackupCodec.importItems(from: backup)

    #expect(report.issues.isEmpty)
    #expect(report.items.map(\.kind) == [.login, .totp, .note, .card, .identity])
    guard report.items.count == 5 else {
        return
    }

    guard case .login(let login) = report.items[0] else {
        Issue.record("Expected legacy login")
        return
    }
    #expect(login.title == "GitHub")
    #expect(login.username == "alice")
    #expect(login.password == "p,ass")
    #expect(login.url == "https://github.com")

    guard case .totp(let totp) = report.items[1] else {
        Issue.record("Expected legacy TOTP")
        return
    }
    #expect(totp.title == "GitHub 2FA")
    #expect(totp.secret == "JBSWY3DPEHPK3PXP")
    #expect(totp.issuer == "GitHub")
    #expect(totp.accountName == "alice")

    guard case .note(let note) = report.items[2] else {
        Issue.record("Expected legacy note")
        return
    }
    #expect(note.title == "Recovery")
    #expect(note.body == "backup codes")

    guard case .card(let card) = report.items[3] else {
        Issue.record("Expected legacy card")
        return
    }
    #expect(card.number == "4111111111111111")
    #expect(card.cardholderName == "Alice Example")
    #expect(card.issuer == "Monica Bank")

    guard case .identity(let identity) = report.items[4] else {
        Issue.record("Expected legacy identity")
        return
    }
    #expect(identity.documentType == "PASSPORT")
    #expect(identity.documentNumber == "P1234567")
    #expect(identity.issuer == "Monica Authority")
}

@Test func androidBackupCodecImportsAttachmentManifestMetadata() throws {
    let backup = try AndroidBackupCodec.exportZip(entries: [
        "folders/Work/passwords/password_42_1710000000000.json": #"{"id":42,"title":"GitHub","username":"alice","password":"secret","website":"https://github.com","categoryName":"Work"}"#,
        "attachments/attachments_meta.json": #"""
        {
          "version": 1,
          "entries": [
            {
              "parentPasswordId": 42,
              "fileName": "contract.pdf",
              "mimeType": "application/pdf",
              "sizeBytes": 2048,
              "sha256Hex": "abc123",
              "wrappedCek": "wrapped-key",
              "localPath": "attachment-1.enc",
              "createdAt": 1710000000000,
              "updatedAt": 1710000001000
            }
          ]
        }
        """#,
        "attachments/attachment-1.enc": "ciphertext"
    ])

    let report = try AndroidBackupCodec.importItems(from: backup)

    #expect(report.items.map(\.kind) == [.login])
    #expect(report.attachments.count == 1)
    guard let attachment = report.attachments.first else {
        return
    }
    #expect(attachment.parentPasswordID == 42)
    #expect(attachment.fileName == "contract.pdf")
    #expect(attachment.mediaType == "application/pdf")
    #expect(attachment.originalSize == 2048)
    #expect(attachment.contentHash == "abc123")
    #expect(attachment.wrappedContentEncryptionKey == "wrapped-key")
    #expect(attachment.localPath == "attachment-1.enc")
    #expect(attachment.blobEntryPath == "attachments/attachment-1.enc")
    #expect(attachment.encryptedBlob == Data("ciphertext".utf8))
}

@Test func androidBackupCodecReportsEncryptedBackupAsUnsupported() throws {
    let encryptedBackup = Data("MONICA_ENC_V1".utf8)
        + Data(repeating: 0, count: 32)
        + Data(repeating: 1, count: 12)
        + Data("ciphertext".utf8)

    let report = try AndroidBackupCodec.importItems(from: encryptedBackup)

    #expect(report.items.isEmpty)
    #expect(report.attachments.isEmpty)
    #expect(report.issues == [
        AndroidBackupImportIssue(
            entryPath: "backup",
            code: .encryptedBackupUnsupported,
            message: "Android 加密备份暂未支持解密，请先从 Android 导出未加密 .zip 后再导入。"
        )
    ])

    let namedReport = try AndroidBackupCodec.importItems(
        from: Data("not-a-zip".utf8),
        fileName: "monica_backup.enc.zip"
    )

    #expect(namedReport.issues == [
        AndroidBackupImportIssue(
            entryPath: "monica_backup.enc.zip",
            code: .encryptedBackupUnsupported,
            message: "Android 加密备份暂未支持解密，请先从 Android 导出未加密 .zip 后再导入。"
        )
    ])
}

@Test func androidBackupCodecDecryptsAndroidEncryptedBackupWithPassword() throws {
    let encryptedBackup = Data(base64Encoded: """
    TU9OSUNBX0VOQ19WMQABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fICEiIyQlJicoKSor3Y7UrXnMGjMyxTjucaTvnqyejqWi9PHsimI3t6aeujIinpZ9V4kzgGj5aN0bqpcK8dZ5GxOGeRjuXpPWnGZoN2XLZQEp9wGTrxF8MQqTNxfnOm3kQLENAOEcvxbnkLSso7VQDZGyUtynn3ysNVxGLbij/lWGBVjV0CrKZvKaMiXUJfmE9WSDZRuHDi1YIg2goD3ubLzMkOctElPzm9JF4YFzeYjGmZxMgNFuWJeerzy9HzcqhMYcGJUEvjmuWz3NybBvnurVJAgizdYXM9kIqjqE9wdr67/qVmw7KyUwfI3CFThAxxg57RFWwBTrf/drVNPUrJDknJTSJZLFkX6US+J6J5zYD8kePndLxF4AS6zj2mzVCNzLJzy9HpBYvrj3ZqchQ7/7hFNqbixH1NjH0+u+wz+aHkJ8LF5jb3bMJg==
    """)!

    let report = try AndroidBackupCodec.importItems(
        from: encryptedBackup,
        fileName: "monica_backup.enc.zip",
        decryptPassword: "correct horse battery staple"
    )

    #expect(report.issues.isEmpty)
    #expect(report.items.map(\.kind) == [.login])
    guard case .login(let login) = report.items.first else {
        Issue.record("Expected decrypted login")
        return
    }
    #expect(login.title == "GitLab")
    #expect(login.username == "dev")
    #expect(login.password == "s3cret")
    #expect(login.url == "https://gitlab.com")

    let failedReport = try AndroidBackupCodec.importItems(
        from: encryptedBackup,
        fileName: "monica_backup.enc.zip",
        decryptPassword: "wrong password"
    )

    #expect(failedReport.items.isEmpty)
    #expect(failedReport.issues == [
        AndroidBackupImportIssue(
            entryPath: "monica_backup.enc.zip",
            code: .encryptedBackupDecryptionFailed,
            message: "Android 加密备份解密失败，请检查密码或文件是否损坏。"
        )
    ])
}

@Test func parityFeatureFlagsKeepUnsupportedAndroidModulesVisibleButDisabled() {
    #expect(ParityFeatureFlag.phaseOneEnabled == [.passwords, .totp, .notes, .wallet, .identities, .settings])
    #expect(ParityFeatureFlag.phaseTwoEnabled == [.passwords, .totp, .notes, .wallet, .identities, .settings, .autofill])
    #expect(ParityFeatureFlag.autofill.isEnabledInPhaseTwo)
    #expect(ParityFeatureFlag.backup.disabledReason == "第三阶段接入 Android 备份兼容。")
    #expect(!ParityFeatureFlag.bitwarden.isEnabledInPhaseOne)
    #expect(!ParityFeatureFlag.passkeys.isEnabledInPhaseOne)
    #expect(ParityFeatureFlag.passkeys.disabledReason == "后续阶段接入 iOS AuthenticationServices。")
}

@Test func createVaultBuildsMDBXDescriptorAndDelegatesToEngine() throws {
    let engine = RecordingVaultEngine()
    let repository = LocalVaultRepository(engine: engine)
    let directory = URL(fileURLWithPath: "/tmp/monica-storage-tests", isDirectory: true)

    let session = try repository.createVault(
        named: "Personal Vault",
        in: directory,
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )

    #expect(session.state == .unlocked)
    #expect(session.descriptor.displayName == "Personal Vault")
    #expect(session.descriptor.fileURL.lastPathComponent == "Personal Vault.mdbx")
    #expect(engine.createdVaults == [
        .init(
            fileURL: directory.appendingPathComponent("Personal Vault.mdbx"),
            password: "中文 password 12345!",
            deviceID: "ios-storage-test"
        )
    ])
}

@Test func createVaultRejectsEmptyNameBeforeCallingEngine() {
    let engine = RecordingVaultEngine()
    let repository = LocalVaultRepository(engine: engine)

    #expect(throws: LocalVaultRepositoryError.emptyVaultName) {
        try repository.createVault(
            named: "  ",
            in: URL(fileURLWithPath: "/tmp", isDirectory: true),
            password: "secret",
            deviceID: "ios-storage-test"
        )
    }
    #expect(engine.createdVaults.isEmpty)
}

@Test func openVaultReturnsUnlockedSession() throws {
    let engine = RecordingVaultEngine()
    let repository = LocalVaultRepository(engine: engine)
    let vaultURL = URL(fileURLWithPath: "/tmp/work.mdbx")

    let session = try repository.openVault(
        at: vaultURL,
        password: "secret",
        deviceID: "ios-storage-test"
    )

    #expect(session.state == .unlocked)
    #expect(session.descriptor.fileURL == vaultURL)
    #expect(session.descriptor.displayName == "work")
    #expect(engine.openedVaults == [
        .init(
            fileURL: vaultURL,
            password: "secret",
            deviceID: "ios-storage-test"
        )
    ])
}

@Test func setupAndOpenVaultWithSecurityKeyMaterialDelegateToEngine() throws {
    let engine = RecordingVaultEngine()
    let repository = LocalVaultRepository(engine: engine)
    let vaultURL = URL(fileURLWithPath: "/tmp/mobile.mdbx")
    let keyMaterial = Data(repeating: 0x2A, count: 32)

    let created = try repository.createVault(
        named: "Mobile",
        in: URL(fileURLWithPath: "/tmp", isDirectory: true),
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    try repository.setupLocalSecurityKeyUnlock(
        for: created,
        securityKeyMaterial: keyMaterial
    )
    let reopened = try repository.openVaultWithSecurityKey(
        at: vaultURL,
        securityKeyMaterial: keyMaterial,
        deviceID: "ios-storage-test"
    )

    #expect(reopened.state == .unlocked)
    #expect(engine.securityKeySetups == [
        .init(vaultID: "created-vault", keyMaterial: keyMaterial)
    ])
    #expect(engine.securityKeyOpenedVaults == [
        .init(fileURL: vaultURL, keyMaterial: keyMaterial, deviceID: "ios-storage-test")
    ])
}

@Test func resetMasterPasswordDelegatesToUnlockedVaultEngine() throws {
    let engine = RecordingVaultEngine()
    let repository = LocalVaultRepository(engine: engine)
    let session = try repository.createVault(
        named: "Mobile",
        in: URL(fileURLWithPath: "/tmp", isDirectory: true),
        password: "old password",
        deviceID: "ios-storage-test"
    )

    try repository.resetMasterPassword(
        for: session,
        newPassword: "new password"
    )

    #expect(engine.resetMasterPasswordCalls == [
        .init(vaultID: "created-vault", newPassword: "new password")
    ])
}

@Test func loginEntryRepositoryCreatesProjectScopedLoginAndListsIt() throws {
    let engine = RecordingVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let session = try vaultRepository.createVault(
        named: "Personal",
        in: URL(fileURLWithPath: "/tmp/monica-storage-tests", isDirectory: true),
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)

    let project = try entryRepository.createProject(title: "Personal")
    let entry = try entryRepository.createLoginEntry(
        projectID: project.id,
        draft: LocalLoginEntryDraft(
            title: "GitHub",
            username: "alice",
            password: "correct horse battery staple",
            url: "https://github.com"
        )
    )
    let entries = try entryRepository.listLoginEntries(projectID: project.id)

    #expect(project.title == "Personal")
    #expect(entry.title == "GitHub")
    #expect(entry.username == "alice")
    #expect(entry.password == "correct horse battery staple")
    #expect(entry.url == "https://github.com")
    #expect(entries == [entry])
    #expect(engine.createdProjects == [
        .init(vaultID: session.handle.vaultID, title: "Personal")
    ])
    #expect(engine.createdLoginEntries.first?.projectID == project.id)
}

@Test func loginEntryRepositoryPreservesLoginNotes() throws {
    let engine = RecordingVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let session = try vaultRepository.createVault(
        named: "Personal",
        in: URL(fileURLWithPath: "/tmp/monica-storage-tests", isDirectory: true),
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)

    let project = try entryRepository.createProject(title: "Personal")
    let entry = try entryRepository.createLoginEntry(
        projectID: project.id,
        draft: LocalLoginEntryDraft(
            title: "GitHub",
            username: "alice",
            password: "correct horse battery staple",
            url: "https://github.com",
            notes: "KeePass notes should survive"
        )
    )
    let updated = try entryRepository.updateLoginEntry(
        projectID: project.id,
        entryID: entry.id,
        draft: LocalLoginEntryDraft(
            title: "GitHub Work",
            username: "alice",
            password: "correct horse battery staple",
            url: "https://github.com/work",
            notes: "Updated login notes"
        )
    )

    #expect(entry.notes == "KeePass notes should survive")
    #expect(updated.notes == "Updated login notes")
    #expect(try entryRepository.listLoginEntries(projectID: project.id) == [updated])
    #expect(engine.createdLoginEntries.first?.draft.notes == "KeePass notes should survive")
    #expect(engine.updatedLoginEntries.first?.draft.notes == "Updated login notes")
}

@Test func entryRepositoryListsRenamesAndDeletesEmptyProjects() throws {
    let engine = RecordingVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let session = try vaultRepository.createVault(
        named: "Personal",
        in: URL(fileURLWithPath: "/tmp/monica-storage-tests", isDirectory: true),
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)

    let personal = try entryRepository.createProject(title: " Personal ")
    let work = try entryRepository.createProject(title: "Work")

    #expect(try entryRepository.listProjects() == [personal, work])

    let renamed = try entryRepository.renameProject(projectID: work.id, title: " Clients ")

    #expect(renamed == LocalVaultProject(id: work.id, title: "Clients"))
    #expect(try entryRepository.listProjects() == [personal, renamed])
    #expect(engine.renamedProjects == [
        .init(vaultID: session.handle.vaultID, projectID: work.id, title: "Clients")
    ])

    try entryRepository.deleteProject(projectID: renamed.id)

    #expect(try entryRepository.listProjects() == [personal])
    #expect(engine.deletedProjects == [
        .init(vaultID: session.handle.vaultID, projectID: renamed.id)
    ])
}

@Test func entryRepositoryRefusesDeletingProjectWithActiveEntries() throws {
    let engine = RecordingVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let session = try vaultRepository.createVault(
        named: "Personal",
        in: URL(fileURLWithPath: "/tmp/monica-storage-tests", isDirectory: true),
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)
    let project = try entryRepository.createProject(title: "Work")

    _ = try entryRepository.createLoginEntry(
        projectID: project.id,
        draft: LocalLoginEntryDraft(
            title: "GitHub",
            username: "alice",
            password: "correct horse battery staple",
            url: "https://github.com"
        )
    )

    #expect(throws: LocalVaultRepositoryError.projectNotEmpty) {
        try entryRepository.deleteProject(projectID: project.id)
    }
    #expect(try entryRepository.listProjects() == [project])
    #expect(engine.deletedProjects.isEmpty)
}

@Test func entryRepositoryMovesEntriesBetweenProjectsPreservingIdentity() throws {
    let engine = RecordingVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let session = try vaultRepository.createVault(
        named: "Personal",
        in: URL(fileURLWithPath: "/tmp/monica-storage-tests", isDirectory: true),
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)
    let personal = try entryRepository.createProject(title: "Personal")
    let work = try entryRepository.createProject(title: "Work")
    let login = try entryRepository.createLoginEntry(
        projectID: personal.id,
        draft: LocalLoginEntryDraft(
            title: "GitHub",
            username: "alice",
            password: "correct horse battery staple",
            url: "https://github.com"
        )
    )
    let note = try entryRepository.createNoteEntry(
        projectID: personal.id,
        draft: LocalNoteEntryDraft(title: "Recovery Codes", body: "github recovery")
    )
    let totp = try entryRepository.createTotpEntry(
        projectID: personal.id,
        draft: LocalTotpEntryDraft(
            title: "GitHub 2FA",
            secret: "JBSWY3DPEHPK3PXP",
            issuer: "GitHub",
            accountName: "alice",
            period: 30,
            digits: 6,
            algorithm: "SHA1",
            otpType: "TOTP",
            counter: 0
        )
    )
    let card = try entryRepository.createCardEntry(
        projectID: personal.id,
        draft: LocalCardEntryDraft(
            title: "Everyday Visa",
            cardholderName: "Alice Example",
            number: "4111111111111111",
            expiryMonth: "12",
            expiryYear: "2031",
            cvv: "123",
            issuer: "Monica Bank",
            network: "Visa",
            notes: "main card"
        )
    )
    let identity = try entryRepository.createIdentityEntry(
        projectID: personal.id,
        draft: LocalIdentityEntryDraft(
            title: "Passport",
            documentType: "PASSPORT",
            fullName: "Alice Example",
            documentNumber: "P1234567",
            issuer: "Monica Authority",
            country: "US",
            issueDate: "2024-01-01",
            expiryDate: "2034-01-01",
            notes: "travel"
        )
    )
    let passkey = try entryRepository.createPasskeyEntry(
        projectID: personal.id,
        draft: LocalPasskeyEntryDraft(
            title: "GitHub Passkey",
            relyingPartyID: "github.com",
            username: "alice",
            userHandle: "user-handle",
            credentialID: "credential-id",
            publicKeyCOSE: "public-key",
            privateKeyReference: "keychain-ref",
            notes: "AuthenticationServices metadata"
        )
    )
    let sshKey = try entryRepository.createSshKeyEntry(
        projectID: personal.id,
        draft: LocalSshKeyEntryDraft(
            title: "Production SSH",
            username: "deploy",
            host: "prod.example.com",
            publicKey: "ssh-ed25519 AAAA",
            privateKeyReference: "keychain-ssh",
            passphraseHint: "vault protected",
            notes: "rotate quarterly"
        )
    )
    let apiToken = try entryRepository.createApiTokenEntry(
        projectID: personal.id,
        draft: LocalApiTokenEntryDraft(
            title: "OpenAI",
            issuer: "OpenAI",
            accountName: "alice@example.com",
            token: "sk-secret",
            scopes: "responses.read",
            expiresAt: "2026-12-31",
            notes: "local-only"
        )
    )
    let wifi = try entryRepository.createWifiEntry(
        projectID: personal.id,
        draft: LocalWifiEntryDraft(
            title: "Studio Wi-Fi",
            ssid: "MonicaLab",
            securityType: "WPA3",
            password: "wifi-secret",
            hidden: false,
            notes: "office"
        )
    )
    let send = try entryRepository.createSendEntry(
        projectID: personal.id,
        draft: LocalSendEntryDraft(
            title: "One-time secret",
            body: "share once",
            expiresAt: "2026-06-02T00:00:00Z",
            maxViews: 1,
            notes: "local metadata"
        )
    )
    let attachment = try entryRepository.createAttachmentMetadata(
        projectID: personal.id,
        entryID: login.id,
        fileName: "passkey-note.txt",
        mediaType: "text/plain",
        originalSize: 128,
        storedSize: 128,
        contentHash: "sha256:attachment",
        storageMode: "embedded-inline"
    )

    let movedEntries = try [
        entryRepository.moveEntry(kind: .login, entryID: login.id, fromProjectID: personal.id, toProjectID: work.id),
        entryRepository.moveEntry(kind: .note, entryID: note.id, fromProjectID: personal.id, toProjectID: work.id),
        entryRepository.moveEntry(kind: .totp, entryID: totp.id, fromProjectID: personal.id, toProjectID: work.id),
        entryRepository.moveEntry(kind: .card, entryID: card.id, fromProjectID: personal.id, toProjectID: work.id),
        entryRepository.moveEntry(kind: .identity, entryID: identity.id, fromProjectID: personal.id, toProjectID: work.id),
        entryRepository.moveEntry(kind: .passkey, entryID: passkey.id, fromProjectID: personal.id, toProjectID: work.id),
        entryRepository.moveEntry(kind: .sshKey, entryID: sshKey.id, fromProjectID: personal.id, toProjectID: work.id),
        entryRepository.moveEntry(kind: .apiToken, entryID: apiToken.id, fromProjectID: personal.id, toProjectID: work.id),
        entryRepository.moveEntry(kind: .wifi, entryID: wifi.id, fromProjectID: personal.id, toProjectID: work.id),
        entryRepository.moveEntry(kind: .send, entryID: send.id, fromProjectID: personal.id, toProjectID: work.id),
        entryRepository.moveEntry(kind: .attachmentRef, entryID: attachment.id, fromProjectID: personal.id, toProjectID: work.id)
    ]

    #expect(movedEntries == [
        LocalVaultMovedEntry(id: login.id, title: "GitHub", kind: .login),
        LocalVaultMovedEntry(id: note.id, title: "Recovery Codes", kind: .note),
        LocalVaultMovedEntry(id: totp.id, title: "GitHub 2FA", kind: .totp),
        LocalVaultMovedEntry(id: card.id, title: "Everyday Visa", kind: .card),
        LocalVaultMovedEntry(id: identity.id, title: "Passport", kind: .identity),
        LocalVaultMovedEntry(id: passkey.id, title: "GitHub Passkey", kind: .passkey),
        LocalVaultMovedEntry(id: sshKey.id, title: "Production SSH", kind: .sshKey),
        LocalVaultMovedEntry(id: apiToken.id, title: "OpenAI", kind: .apiToken),
        LocalVaultMovedEntry(id: wifi.id, title: "Studio Wi-Fi", kind: .wifi),
        LocalVaultMovedEntry(id: send.id, title: "One-time secret", kind: .send),
        LocalVaultMovedEntry(id: attachment.id, title: "passkey-note.txt", kind: .attachmentRef)
    ])
    #expect(try entryRepository.listLoginEntries(projectID: personal.id).isEmpty)
    #expect(try entryRepository.listNoteEntries(projectID: personal.id).isEmpty)
    #expect(try entryRepository.listTotpEntries(projectID: personal.id).isEmpty)
    #expect(try entryRepository.listCardEntries(projectID: personal.id).isEmpty)
    #expect(try entryRepository.listIdentityEntries(projectID: personal.id).isEmpty)
    #expect(try entryRepository.listPasskeyEntries(projectID: personal.id).isEmpty)
    #expect(try entryRepository.listSshKeyEntries(projectID: personal.id).isEmpty)
    #expect(try entryRepository.listApiTokenEntries(projectID: personal.id).isEmpty)
    #expect(try entryRepository.listWifiEntries(projectID: personal.id).isEmpty)
    #expect(try entryRepository.listSendEntries(projectID: personal.id).isEmpty)
    #expect(try entryRepository.listAttachmentMetadata(projectID: personal.id).isEmpty)
    #expect(try entryRepository.listLoginEntries(projectID: work.id).map(\.id) == [login.id])
    #expect(try entryRepository.listNoteEntries(projectID: work.id).map(\.id) == [note.id])
    #expect(try entryRepository.listTotpEntries(projectID: work.id).map(\.id) == [totp.id])
    #expect(try entryRepository.listCardEntries(projectID: work.id).map(\.id) == [card.id])
    #expect(try entryRepository.listIdentityEntries(projectID: work.id).map(\.id) == [identity.id])
    #expect(try entryRepository.listPasskeyEntries(projectID: work.id).map(\.id) == [passkey.id])
    #expect(try entryRepository.listSshKeyEntries(projectID: work.id).map(\.id) == [sshKey.id])
    #expect(try entryRepository.listApiTokenEntries(projectID: work.id).map(\.id) == [apiToken.id])
    #expect(try entryRepository.listWifiEntries(projectID: work.id).map(\.id) == [wifi.id])
    #expect(try entryRepository.listSendEntries(projectID: work.id).map(\.id) == [send.id])
    #expect(try entryRepository.listAttachmentMetadata(projectID: work.id).map(\.id) == [attachment.id])
    #expect(try entryRepository.listLoginEntries(projectID: work.id).first?.projectID == work.id)
    #expect(engine.movedVaultEntries.map(\.kind) == [
        .login,
        .note,
        .totp,
        .card,
        .identity,
        .passkey,
        .sshKey,
        .apiToken,
        .wifi,
        .send,
        .attachmentRef
    ])
}

@Test func loginEntryRepositoryUpdatesProjectScopedLoginAndListsUpdatedEntry() throws {
    let engine = RecordingVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let session = try vaultRepository.createVault(
        named: "Personal",
        in: URL(fileURLWithPath: "/tmp/monica-storage-tests", isDirectory: true),
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)

    let project = try entryRepository.createProject(title: "Personal")
    let created = try entryRepository.createLoginEntry(
        projectID: project.id,
        draft: LocalLoginEntryDraft(
            title: "GitHub",
            username: "alice",
            password: "old-password",
            url: "https://github.com"
        )
    )

    let updated = try entryRepository.updateLoginEntry(
        projectID: project.id,
        entryID: created.id,
        draft: LocalLoginEntryDraft(
            title: "GitHub Work",
            username: "alice@example.com",
            password: "new-password",
            url: "https://github.com/settings/profile"
        )
    )
    let entries = try entryRepository.listLoginEntries(projectID: project.id)

    #expect(updated.id == created.id)
    #expect(updated.title == "GitHub Work")
    #expect(updated.username == "alice@example.com")
    #expect(updated.password == "new-password")
    #expect(updated.url == "https://github.com/settings/profile")
    #expect(entries == [updated])
    #expect(engine.updatedLoginEntries == [
        .init(
            vaultID: session.handle.vaultID,
            projectID: project.id,
            entryID: created.id,
            draft: LocalLoginEntryDraft(
                title: "GitHub Work",
                username: "alice@example.com",
                password: "new-password",
                url: "https://github.com/settings/profile"
            )
        )
    ])
}

@Test func loginEntryRepositorySetsFavoriteWithoutChangingPayloadFields() throws {
    let engine = RecordingVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let session = try vaultRepository.createVault(
        named: "Personal",
        in: URL(fileURLWithPath: "/tmp/monica-storage-tests", isDirectory: true),
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)

    let project = try entryRepository.createProject(title: "Personal")
    let created = try entryRepository.createLoginEntry(
        projectID: project.id,
        draft: LocalLoginEntryDraft(
            title: "GitHub",
            username: "alice",
            password: "correct horse battery staple",
            url: "https://github.com"
        )
    )

    let favorited = try entryRepository.setLoginEntryFavorite(
        projectID: project.id,
        entryID: created.id,
        favorite: true
    )
    let entries = try entryRepository.listLoginEntries(projectID: project.id)

    #expect(!created.favorite)
    #expect(favorited.favorite)
    #expect(favorited.title == "GitHub")
    #expect(favorited.password == "correct horse battery staple")
    #expect(entries == [favorited])
    #expect(engine.favoritedLoginEntries == [
        .init(
            vaultID: session.handle.vaultID,
            projectID: project.id,
            entryID: created.id,
            favorite: true
        )
    ])
}

@Test func typedEntryRepositoriesSetFavoriteWithoutChangingPayloadFields() throws {
    let engine = RecordingVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let session = try vaultRepository.createVault(
        named: "Personal",
        in: URL(fileURLWithPath: "/tmp/monica-storage-tests", isDirectory: true),
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)

    let project = try entryRepository.createProject(title: "Personal")
    let note = try entryRepository.createNoteEntry(
        projectID: project.id,
        draft: LocalNoteEntryDraft(title: "Recovery", body: "code-1")
    )
    let totp = try entryRepository.createTotpEntry(
        projectID: project.id,
        draft: LocalTotpEntryDraft(
            title: "GitHub TOTP",
            secret: "JBSWY3DPEHPK3PXP",
            issuer: "GitHub",
            accountName: "alice",
            period: 30,
            digits: 6,
            algorithm: "SHA1",
            otpType: "TOTP",
            counter: 0
        )
    )
    let card = try entryRepository.createCardEntry(
        projectID: project.id,
        draft: LocalCardEntryDraft(
            title: "Everyday Visa",
            cardholderName: "Alice Example",
            number: "4111111111111111",
            expiryMonth: "12",
            expiryYear: "2031",
            cvv: "123",
            issuer: "Monica Bank",
            network: "Visa",
            notes: "Primary checking card"
        )
    )
    let identity = try entryRepository.createIdentityEntry(
        projectID: project.id,
        draft: LocalIdentityEntryDraft(
            title: "Passport",
            documentType: "passport",
            fullName: "Alice Example",
            documentNumber: "P1234567",
            issuer: "Monica Authority",
            country: "US",
            issueDate: "2026-01-02",
            expiryDate: "2036-01-01",
            notes: "Primary travel document"
        )
    )

    let favoritedNote = try entryRepository.setNoteEntryFavorite(
        projectID: project.id,
        entryID: note.id,
        favorite: true
    )
    let favoritedTotp = try entryRepository.setTotpEntryFavorite(
        projectID: project.id,
        entryID: totp.id,
        favorite: true
    )
    let favoritedCard = try entryRepository.setCardEntryFavorite(
        projectID: project.id,
        entryID: card.id,
        favorite: true
    )
    let favoritedIdentity = try entryRepository.setIdentityEntryFavorite(
        projectID: project.id,
        entryID: identity.id,
        favorite: true
    )

    #expect(!note.favorite)
    #expect(!totp.favorite)
    #expect(!card.favorite)
    #expect(!identity.favorite)
    #expect(favoritedNote.favorite)
    #expect(favoritedNote.body == "code-1")
    #expect(favoritedTotp.favorite)
    #expect(favoritedTotp.secret == "JBSWY3DPEHPK3PXP")
    #expect(favoritedCard.favorite)
    #expect(favoritedCard.number == "4111111111111111")
    #expect(favoritedIdentity.favorite)
    #expect(favoritedIdentity.documentNumber == "P1234567")
    #expect(engine.favoritedNoteEntries == [
        .init(vaultID: session.handle.vaultID, projectID: project.id, entryID: note.id, favorite: true)
    ])
    #expect(engine.favoritedTotpEntries == [
        .init(vaultID: session.handle.vaultID, projectID: project.id, entryID: totp.id, favorite: true)
    ])
    #expect(engine.favoritedCardEntries == [
        .init(vaultID: session.handle.vaultID, projectID: project.id, entryID: card.id, favorite: true)
    ])
    #expect(engine.favoritedIdentityEntries == [
        .init(vaultID: session.handle.vaultID, projectID: project.id, entryID: identity.id, favorite: true)
    ])
}

@Test func noteEntryRepositoryCreatesUpdatesDeletesAndRestoresProjectScopedNote() throws {
    let engine = RecordingVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let session = try vaultRepository.createVault(
        named: "Personal",
        in: URL(fileURLWithPath: "/tmp/monica-storage-tests", isDirectory: true),
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)
    let project = try entryRepository.createProject(title: "Personal")

    let created = try entryRepository.createNoteEntry(
        projectID: project.id,
        draft: LocalNoteEntryDraft(title: "Recovery codes", body: "code-1\ncode-2")
    )
    let updated = try entryRepository.updateNoteEntry(
        projectID: project.id,
        entryID: created.id,
        draft: LocalNoteEntryDraft(title: "Recovery codes updated", body: "code-3\ncode-4")
    )
    try entryRepository.deleteNoteEntry(projectID: project.id, entryID: created.id)
    let deleted = try entryRepository.listDeletedNoteEntries(projectID: project.id)
    let restored = try entryRepository.restoreNoteEntry(projectID: project.id, entryID: created.id)
    let notes = try entryRepository.listNoteEntries(projectID: project.id)

    #expect(created.title == "Recovery codes")
    #expect(updated.id == created.id)
    #expect(updated.body == "code-3\ncode-4")
    #expect(deleted == [updated])
    #expect(restored == updated)
    #expect(notes == [updated])
    #expect(engine.createdNoteEntries.first?.projectID == project.id)
    #expect(engine.updatedNoteEntries.first?.entryID == created.id)
    #expect(engine.deletedNoteEntries.first?.entryID == created.id)
    #expect(engine.restoredNoteEntries.first?.entryID == created.id)
}

@Test func totpEntryRepositoryCreatesUpdatesDeletesAndRestoresProjectScopedTotp() throws {
    let engine = RecordingVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let session = try vaultRepository.createVault(
        named: "Personal",
        in: URL(fileURLWithPath: "/tmp/monica-storage-tests", isDirectory: true),
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)
    let project = try entryRepository.createProject(title: "Personal")

    let created = try entryRepository.createTotpEntry(
        projectID: project.id,
        draft: LocalTotpEntryDraft(
            title: "GitHub TOTP",
            secret: "JBSWY3DPEHPK3PXP",
            issuer: "GitHub",
            accountName: "alice",
            period: 30,
            digits: 6,
            algorithm: "SHA1",
            otpType: "TOTP",
            counter: 0
        )
    )
    let updated = try entryRepository.updateTotpEntry(
        projectID: project.id,
        entryID: created.id,
        draft: LocalTotpEntryDraft(
            title: "GitHub Work TOTP",
            secret: "JBSWY3DPEHPK3PXQ",
            issuer: "GitHub",
            accountName: "alice@example.com",
            period: 60,
            digits: 8,
            algorithm: "SHA256",
            otpType: "TOTP",
            counter: 0
        )
    )
    try entryRepository.deleteTotpEntry(projectID: project.id, entryID: created.id)
    let deleted = try entryRepository.listDeletedTotpEntries(projectID: project.id)
    let restored = try entryRepository.restoreTotpEntry(projectID: project.id, entryID: created.id)
    let totpEntries = try entryRepository.listTotpEntries(projectID: project.id)

    #expect(created.title == "GitHub TOTP")
    #expect(created.secret == "JBSWY3DPEHPK3PXP")
    #expect(created.issuer == "GitHub")
    #expect(created.accountName == "alice")
    #expect(created.period == 30)
    #expect(created.digits == 6)
    #expect(created.algorithm == "SHA1")
    #expect(created.otpType == "TOTP")
    #expect(created.counter == 0)
    #expect(updated.id == created.id)
    #expect(updated.title == "GitHub Work TOTP")
    #expect(updated.secret == "JBSWY3DPEHPK3PXQ")
    #expect(updated.accountName == "alice@example.com")
    #expect(updated.period == 60)
    #expect(updated.digits == 8)
    #expect(updated.algorithm == "SHA256")
    #expect(deleted == [updated])
    #expect(restored == updated)
    #expect(totpEntries == [updated])
    #expect(engine.createdTotpEntries.first?.projectID == project.id)
    #expect(engine.updatedTotpEntries.first?.entryID == created.id)
    #expect(engine.deletedTotpEntries.first?.entryID == created.id)
    #expect(engine.restoredTotpEntries.first?.entryID == created.id)
}

@Test func cardEntryRepositoryCreatesUpdatesDeletesAndRestoresProjectScopedCard() throws {
    let engine = RecordingVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let session = try vaultRepository.createVault(
        named: "Personal",
        in: URL(fileURLWithPath: "/tmp/monica-storage-tests", isDirectory: true),
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)
    let project = try entryRepository.createProject(title: "Personal")

    let created = try entryRepository.createCardEntry(
        projectID: project.id,
        draft: LocalCardEntryDraft(
            title: "Everyday Visa",
            cardholderName: "Alice Example",
            number: "4111111111111111",
            expiryMonth: "12",
            expiryYear: "2031",
            cvv: "123",
            issuer: "Monica Bank",
            network: "Visa",
            notes: "Primary checking card"
        )
    )
    let updated = try entryRepository.updateCardEntry(
        projectID: project.id,
        entryID: created.id,
        draft: LocalCardEntryDraft(
            title: "Travel Mastercard",
            cardholderName: "Alice Q. Example",
            number: "5555555555554444",
            expiryMonth: "01",
            expiryYear: "2032",
            cvv: "456",
            issuer: "Monica Credit Union",
            network: "Mastercard",
            notes: "No foreign transaction fee"
        )
    )
    try entryRepository.deleteCardEntry(projectID: project.id, entryID: created.id)
    let deleted = try entryRepository.listDeletedCardEntries(projectID: project.id)
    let restored = try entryRepository.restoreCardEntry(projectID: project.id, entryID: created.id)
    let cardEntries = try entryRepository.listCardEntries(projectID: project.id)

    #expect(created.title == "Everyday Visa")
    #expect(created.cardholderName == "Alice Example")
    #expect(created.number == "4111111111111111")
    #expect(created.expiryMonth == "12")
    #expect(created.expiryYear == "2031")
    #expect(created.cvv == "123")
    #expect(created.issuer == "Monica Bank")
    #expect(created.network == "Visa")
    #expect(updated.id == created.id)
    #expect(updated.title == "Travel Mastercard")
    #expect(updated.number == "5555555555554444")
    #expect(updated.cvv == "456")
    #expect(deleted == [updated])
    #expect(restored == updated)
    #expect(cardEntries == [updated])
    #expect(engine.createdCardEntries.first?.projectID == project.id)
    #expect(engine.updatedCardEntries.first?.entryID == created.id)
    #expect(engine.deletedCardEntries.first?.entryID == created.id)
    #expect(engine.restoredCardEntries.first?.entryID == created.id)
}

@Test func identityEntryRepositoryCreatesUpdatesDeletesAndRestoresProjectScopedIdentity() throws {
    let engine = RecordingVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let session = try vaultRepository.createVault(
        named: "Personal",
        in: URL(fileURLWithPath: "/tmp/monica-storage-tests", isDirectory: true),
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)
    let project = try entryRepository.createProject(title: "Personal")

    let created = try entryRepository.createIdentityEntry(
        projectID: project.id,
        draft: LocalIdentityEntryDraft(
            title: "Passport",
            documentType: "passport",
            fullName: "Alice Example",
            documentNumber: "P1234567",
            issuer: "Monica Authority",
            country: "US",
            issueDate: "2026-01-02",
            expiryDate: "2036-01-01",
            notes: "Primary travel document"
        )
    )
    let updated = try entryRepository.updateIdentityEntry(
        projectID: project.id,
        entryID: created.id,
        draft: LocalIdentityEntryDraft(
            title: "Driver License",
            documentType: "driver_license",
            fullName: "Alice Q. Example",
            documentNumber: "D7654321",
            issuer: "Monica DMV",
            country: "US-CA",
            issueDate: "2026-05-31",
            expiryDate: "2031-05-30",
            notes: "State license metadata"
        )
    )
    try entryRepository.deleteIdentityEntry(projectID: project.id, entryID: created.id)
    let deleted = try entryRepository.listDeletedIdentityEntries(projectID: project.id)
    let restored = try entryRepository.restoreIdentityEntry(projectID: project.id, entryID: created.id)
    let identityEntries = try entryRepository.listIdentityEntries(projectID: project.id)

    #expect(created.title == "Passport")
    #expect(created.documentType == "passport")
    #expect(created.fullName == "Alice Example")
    #expect(created.documentNumber == "P1234567")
    #expect(created.issuer == "Monica Authority")
    #expect(created.country == "US")
    #expect(updated.id == created.id)
    #expect(updated.title == "Driver License")
    #expect(updated.documentType == "driver_license")
    #expect(updated.documentNumber == "D7654321")
    #expect(updated.country == "US-CA")
    #expect(deleted == [updated])
    #expect(restored == updated)
    #expect(identityEntries == [updated])
    #expect(engine.createdIdentityEntries.first?.projectID == project.id)
    #expect(engine.updatedIdentityEntries.first?.entryID == created.id)
    #expect(engine.deletedIdentityEntries.first?.entryID == created.id)
    #expect(engine.restoredIdentityEntries.first?.entryID == created.id)
}

@Test func androidParityEntryRepositoriesCreateUpdateFavoriteDeleteAndRestore() throws {
    let engine = RecordingVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let session = try vaultRepository.createVault(
        named: "Personal",
        in: URL(fileURLWithPath: "/tmp/monica-storage-tests", isDirectory: true),
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)
    let project = try entryRepository.createProject(title: "Personal")

    let passkey = try entryRepository.createPasskeyEntry(
        projectID: project.id,
        draft: LocalPasskeyEntryDraft(
            title: "GitHub Passkey",
            relyingPartyID: "github.com",
            username: "alice",
            userHandle: "user-handle",
            credentialID: "credential-id",
            publicKeyCOSE: "public-key",
            privateKeyReference: "keychain-ref",
            notes: "iOS AuthenticationServices metadata"
        )
    )
    let updatedPasskey = try entryRepository.updatePasskeyEntry(
        projectID: project.id,
        entryID: passkey.id,
        draft: LocalPasskeyEntryDraft(
            title: "GitHub Work Passkey",
            relyingPartyID: "github.com",
            username: "alice@example.com",
            userHandle: "user-handle-2",
            credentialID: "credential-id-2",
            publicKeyCOSE: "public-key-2",
            privateKeyReference: "keychain-ref-2",
            notes: "updated metadata"
        )
    )
    let favoritedPasskey = try entryRepository.setPasskeyEntryFavorite(
        projectID: project.id,
        entryID: passkey.id,
        favorite: true
    )
    try entryRepository.deletePasskeyEntry(projectID: project.id, entryID: passkey.id)
    #expect(try entryRepository.listDeletedPasskeyEntries(projectID: project.id) == [favoritedPasskey])
    #expect(try entryRepository.restorePasskeyEntry(projectID: project.id, entryID: passkey.id) == favoritedPasskey)

    let sshKey = try entryRepository.createSshKeyEntry(
        projectID: project.id,
        draft: LocalSshKeyEntryDraft(
            title: "Production SSH",
            username: "deploy",
            host: "prod.example.com",
            publicKey: "ssh-ed25519 AAAA",
            privateKeyReference: "keychain-ssh",
            passphraseHint: "vault protected",
            notes: "rotate quarterly"
        )
    )
    let updatedSshKey = try entryRepository.updateSshKeyEntry(
        projectID: project.id,
        entryID: sshKey.id,
        draft: LocalSshKeyEntryDraft(
            title: "Staging SSH",
            username: "deploy",
            host: "staging.example.com",
            publicKey: "ssh-ed25519 BBBB",
            privateKeyReference: "keychain-ssh-2",
            passphraseHint: "stored separately",
            notes: "limited access"
        )
    )
    let favoritedSshKey = try entryRepository.setSshKeyEntryFavorite(
        projectID: project.id,
        entryID: sshKey.id,
        favorite: true
    )
    try entryRepository.deleteSshKeyEntry(projectID: project.id, entryID: sshKey.id)
    #expect(try entryRepository.listDeletedSshKeyEntries(projectID: project.id) == [favoritedSshKey])
    #expect(try entryRepository.restoreSshKeyEntry(projectID: project.id, entryID: sshKey.id) == favoritedSshKey)

    let apiToken = try entryRepository.createApiTokenEntry(
        projectID: project.id,
        draft: LocalApiTokenEntryDraft(
            title: "OpenAI",
            issuer: "OpenAI",
            accountName: "alice@example.com",
            token: "sk-secret",
            scopes: "responses.read",
            expiresAt: "2026-12-31",
            notes: "local-only"
        )
    )
    let updatedApiToken = try entryRepository.updateApiTokenEntry(
        projectID: project.id,
        entryID: apiToken.id,
        draft: LocalApiTokenEntryDraft(
            title: "OpenAI Build",
            issuer: "OpenAI",
            accountName: "build@example.com",
            token: "sk-secret-2",
            scopes: "responses.write",
            expiresAt: "2027-12-31",
            notes: "rotation candidate"
        )
    )
    let favoritedApiToken = try entryRepository.setApiTokenEntryFavorite(
        projectID: project.id,
        entryID: apiToken.id,
        favorite: true
    )
    try entryRepository.deleteApiTokenEntry(projectID: project.id, entryID: apiToken.id)
    #expect(try entryRepository.listDeletedApiTokenEntries(projectID: project.id) == [favoritedApiToken])
    #expect(try entryRepository.restoreApiTokenEntry(projectID: project.id, entryID: apiToken.id) == favoritedApiToken)

    let wifi = try entryRepository.createWifiEntry(
        projectID: project.id,
        draft: LocalWifiEntryDraft(
            title: "Studio Wi-Fi",
            ssid: "MonicaLab",
            securityType: "WPA3",
            password: "wifi-secret",
            hidden: false,
            notes: "office"
        )
    )
    let updatedWifi = try entryRepository.updateWifiEntry(
        projectID: project.id,
        entryID: wifi.id,
        draft: LocalWifiEntryDraft(
            title: "Guest Wi-Fi",
            ssid: "MonicaGuest",
            securityType: "WPA2",
            password: "guest-secret",
            hidden: true,
            notes: "visitor network"
        )
    )
    let favoritedWifi = try entryRepository.setWifiEntryFavorite(
        projectID: project.id,
        entryID: wifi.id,
        favorite: true
    )
    try entryRepository.deleteWifiEntry(projectID: project.id, entryID: wifi.id)
    #expect(try entryRepository.listDeletedWifiEntries(projectID: project.id) == [favoritedWifi])
    #expect(try entryRepository.restoreWifiEntry(projectID: project.id, entryID: wifi.id) == favoritedWifi)

    let send = try entryRepository.createSendEntry(
        projectID: project.id,
        draft: LocalSendEntryDraft(
            title: "One-time secret",
            body: "share once",
            expiresAt: "2026-06-02T00:00:00Z",
            maxViews: 1,
            notes: "local metadata"
        )
    )
    let updatedSend = try entryRepository.updateSendEntry(
        projectID: project.id,
        entryID: send.id,
        draft: LocalSendEntryDraft(
            title: "One-day secret",
            body: "share within a day",
            expiresAt: "2026-06-03T00:00:00Z",
            maxViews: 3,
            notes: "local metadata updated"
        )
    )
    let favoritedSend = try entryRepository.setSendEntryFavorite(
        projectID: project.id,
        entryID: send.id,
        favorite: true
    )
    try entryRepository.deleteSendEntry(projectID: project.id, entryID: send.id)
    #expect(try entryRepository.listDeletedSendEntries(projectID: project.id) == [favoritedSend])
    #expect(try entryRepository.restoreSendEntry(projectID: project.id, entryID: send.id) == favoritedSend)

    let attachment = try entryRepository.createAttachmentMetadata(
        projectID: project.id,
        entryID: passkey.id,
        fileName: "passkey-note.txt",
        mediaType: "text/plain",
        originalSize: 128,
        storedSize: 96,
        contentHash: "sha256:attachment",
        storageMode: "embedded-inline"
    )
    try entryRepository.deleteAttachmentMetadata(projectID: project.id, attachmentID: attachment.id)
    #expect(try entryRepository.listDeletedAttachmentMetadata(projectID: project.id) == [
        LocalAttachmentMetadata(
            id: attachment.id,
            projectID: project.id,
            entryID: passkey.id,
            fileName: "passkey-note.txt",
            mediaType: "text/plain",
            originalSize: 128,
            storedSize: 96,
            contentHash: "sha256:attachment",
            storageMode: "embedded-inline",
            deleted: true
        )
    ])
    #expect(try entryRepository.restoreAttachmentMetadata(projectID: project.id, attachmentID: attachment.id) == attachment)

    #expect(updatedPasskey.username == "alice@example.com")
    #expect(updatedSshKey.host == "staging.example.com")
    #expect(updatedApiToken.token == "sk-secret-2")
    #expect(updatedWifi.hidden)
    #expect(updatedSend.maxViews == 3)
    #expect(try entryRepository.listPasskeyEntries(projectID: project.id) == [favoritedPasskey])
    #expect(try entryRepository.listSshKeyEntries(projectID: project.id) == [favoritedSshKey])
    #expect(try entryRepository.listApiTokenEntries(projectID: project.id) == [favoritedApiToken])
    #expect(try entryRepository.listWifiEntries(projectID: project.id) == [favoritedWifi])
    #expect(try entryRepository.listSendEntries(projectID: project.id) == [favoritedSend])
    #expect(try entryRepository.listAttachmentMetadata(projectID: project.id) == [attachment])
    #expect(engine.createdPasskeyEntries.first?.projectID == project.id)
    #expect(engine.updatedPasskeyEntries.first?.entryID == passkey.id)
    #expect(engine.favoritedPasskeyEntries.first?.favorite == true)
    #expect(engine.createdAttachmentMetadata.first?.fileName == "passkey-note.txt")
}

@Test func loginEntryRepositoryDeletesAndRestoresProjectScopedLogin() throws {
    let engine = RecordingVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let session = try vaultRepository.createVault(
        named: "Personal",
        in: URL(fileURLWithPath: "/tmp/monica-storage-tests", isDirectory: true),
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)

    let project = try entryRepository.createProject(title: "Personal")
    let created = try entryRepository.createLoginEntry(
        projectID: project.id,
        draft: LocalLoginEntryDraft(
            title: "GitHub",
            username: "alice",
            password: "correct horse battery staple",
            url: "https://github.com"
        )
    )

    try entryRepository.deleteLoginEntry(projectID: project.id, entryID: created.id)

    #expect(try entryRepository.listLoginEntries(projectID: project.id).isEmpty)
    #expect(try entryRepository.listDeletedLoginEntries(projectID: project.id) == [created])

    let restored = try entryRepository.restoreLoginEntry(projectID: project.id, entryID: created.id)

    #expect(restored == created)
    #expect(try entryRepository.listLoginEntries(projectID: project.id) == [created])
    #expect(try entryRepository.listDeletedLoginEntries(projectID: project.id).isEmpty)
    #expect(engine.deletedLoginEntries == [
        .init(vaultID: session.handle.vaultID, projectID: project.id, entryID: created.id)
    ])
    #expect(engine.restoredLoginEntries == [
        .init(vaultID: session.handle.vaultID, projectID: project.id, entryID: created.id)
    ])
}

@Test func localAttachmentContentDecryptorOpensAndroidEncryptedBlobWithRawCek() throws {
    let cek = Data((0..<32).map(UInt8.init))
    let nonceData = Data((100..<112).map(UInt8.init))
    let plaintext = Data("contract body for preview".utf8)
    let sealedBox = try AES.GCM.seal(
        plaintext,
        using: SymmetricKey(data: cek),
        nonce: try AES.GCM.Nonce(data: nonceData)
    )
    let encryptedBlob = try #require(sealedBox.combined)

    let decrypted = try LocalAttachmentContentDecryptor.decryptAndroidLocalBlob(
        encryptedBlob,
        contentEncryptionKey: cek
    )

    #expect(decrypted == plaintext)
}

@Test func localAttachmentContentDecryptorRejectsInvalidAndroidBlobWithoutLeakingSecrets() throws {
    let cek = Data((0..<32).map(UInt8.init))
    let secretBlob = Data("secret".utf8)

    #expect(throws: LocalAttachmentContentCryptoError.invalidEncryptedBlob) {
        _ = try LocalAttachmentContentDecryptor.decryptAndroidLocalBlob(
            secretBlob,
            contentEncryptionKey: cek
        )
    }
    #expect(throws: LocalAttachmentContentCryptoError.invalidContentEncryptionKeyLength) {
        _ = try LocalAttachmentContentDecryptor.decryptAndroidLocalBlob(
            secretBlob,
            contentEncryptionKey: Data(repeating: 1, count: 31)
        )
    }
    #expect(!LocalAttachmentContentCryptoError.invalidEncryptedBlob.localizedDescription.contains("secret"))
    #expect(!LocalAttachmentContentCryptoError.authenticationFailed.localizedDescription.contains("secret"))
}

@Test func androidWrappedAttachmentContentKeyUnwrapperOpensMdkWrappedCekWithoutLeakingSecrets() throws {
    let cek = Data((0..<32).map(UInt8.init))
    let mdk = Data((100..<132).map(UInt8.init))
    let nonceData = Data((40..<52).map(UInt8.init))
    let base64Cek = cek.base64EncodedString()
    let sealedBox = try AES.GCM.seal(
        Data(base64Cek.utf8),
        using: SymmetricKey(data: mdk),
        nonce: try AES.GCM.Nonce(data: nonceData)
    )
    let wrappedPayload = try #require(sealedBox.combined)
    let wrapped = "MDK|" + wrappedPayload.base64EncodedString()

    let unwrapped = try AndroidWrappedAttachmentContentKeyUnwrapper.unwrap(
        wrapped,
        using: .mdk(mdk)
    )

    #expect(unwrapped == cek)

    var corruptedPayload = wrappedPayload
    corruptedPayload[corruptedPayload.count - 1] ^= 0x01
    let corruptedWrapped = "MDK|" + corruptedPayload.base64EncodedString()
    #expect(throws: LocalAttachmentContentCryptoError.authenticationFailed) {
        _ = try AndroidWrappedAttachmentContentKeyUnwrapper.unwrap(
            corruptedWrapped,
            using: .mdk(mdk)
        )
    }
    #expect(!LocalAttachmentContentCryptoError.authenticationFailed.localizedDescription.contains(base64Cek))
    #expect(!LocalAttachmentContentCryptoError.authenticationFailed.localizedDescription.contains(mdk.map { String(format: "%02x", $0) }.joined()))
}

@Test func encryptedAutoFillIndexStoreSavesAndLoadsEnvelope() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = FileAutoFillEncryptedIndexStore(appGroupContainerURL: directory)
    let index = AutoFillEncryptedIndex(
        vaultID: "vault-1",
        keyIdentifier: "autofill-key-1",
        updatedAt: Date(timeIntervalSince1970: 1_800_100_000),
        records: [
            AutoFillEncryptedIndexRecord(
                id: "record-1",
                nonce: Data([1, 2, 3]),
                ciphertext: Data([4, 5, 6]),
                authenticationTag: Data([7, 8, 9])
            )
        ]
    )

    try store.save(index)

    #expect(try store.load() == index)
}

@Test func encryptedAutoFillIndexFileDoesNotContainPlaintextCredentialMetadata() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = FileAutoFillEncryptedIndexStore(appGroupContainerURL: directory)
    let index = AutoFillEncryptedIndex(
        vaultID: "vault-1",
        keyIdentifier: "autofill-key-1",
        updatedAt: Date(timeIntervalSince1970: 1_800_100_000),
        records: [
            AutoFillEncryptedIndexRecord(
                id: "record-1",
                nonce: Data([10, 11, 12]),
                ciphertext: Data([13, 14, 15]),
                authenticationTag: Data([16, 17, 18])
            )
        ]
    )

    try store.save(index)

    let rawIndex = try String(contentsOf: store.indexFileURL, encoding: .utf8)
    #expect(!rawIndex.contains("github.com"))
    #expect(!rawIndex.contains("alice@example.com"))
    #expect(!rawIndex.contains("GitHub"))
}

@Test func encryptedAutoFillIndexStoreReturnsNilWhenIndexIsMissing() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = FileAutoFillEncryptedIndexStore(appGroupContainerURL: directory)

    #expect(try store.load() == nil)
}

@Test func autoFillIndexCodecEncryptsAndDecryptsCredentialMetadata() throws {
    let codec = AutoFillEncryptedIndexCodec()
    let key = try AutoFillIndexEncryptionKey(rawValue: Data(repeating: 7, count: 32))
    let records = [
        AutoFillCredentialIndexRecord(
            id: "entry-1",
            title: "GitHub",
            username: "alice@example.com",
            serviceIdentifiers: ["github.com", "https://github.com/login"]
        )
    ]

    let index = try codec.encrypt(
        records,
        vaultID: "vault-1",
        keyIdentifier: "autofill-key-1",
        updatedAt: Date(timeIntervalSince1970: 1_800_100_000),
        key: key
    )

    #expect(index.vaultID == "vault-1")
    #expect(index.keyIdentifier == "autofill-key-1")
    #expect(index.records.count == 1)
    #expect(index.records.first?.id == "entry-1")
    #expect(index.records.first?.ciphertext.isEmpty == false)

    let decrypted = try codec.decrypt(index, key: key)

    #expect(decrypted == records)
}

@Test func autoFillIndexCodecDoesNotEncodePlaintextCredentialMetadata() throws {
    let codec = AutoFillEncryptedIndexCodec()
    let key = try AutoFillIndexEncryptionKey(rawValue: Data(repeating: 9, count: 32))
    let index = try codec.encrypt(
        [
            AutoFillCredentialIndexRecord(
                id: "entry-1",
                title: "GitHub",
                username: "alice@example.com",
                serviceIdentifiers: ["github.com"]
            )
        ],
        vaultID: "vault-1",
        keyIdentifier: "autofill-key-1",
        updatedAt: Date(timeIntervalSince1970: 1_800_100_000),
        key: key
    )

    let encoded = try JSONEncoder().encode(index)
    let rawIndex = try #require(String(data: encoded, encoding: .utf8))

    #expect(!rawIndex.contains("github.com"))
    #expect(!rawIndex.contains("alice@example.com"))
    #expect(!rawIndex.contains("GitHub"))
}

@Test func autoFillUnlockedIndexSearchesAndMatchesDecryptedCredentialMetadata() throws {
    let codec = AutoFillEncryptedIndexCodec()
    let key = try AutoFillIndexEncryptionKey(rawValue: Data(repeating: 17, count: 32))
    let encryptedIndex = try codec.encrypt(
        [
            AutoFillCredentialIndexRecord(
                id: "entry-1",
                title: "GitHub",
                username: "alice@example.com",
                serviceIdentifiers: ["github.com", "https://github.com/login"]
            ),
            AutoFillCredentialIndexRecord(
                id: "entry-2",
                title: "Apple ID",
                username: "bob@example.com",
                serviceIdentifiers: ["appleid.apple.com"]
            )
        ],
        vaultID: "vault-1",
        keyIdentifier: "autofill-key-1",
        updatedAt: Date(timeIntervalSince1970: 1_800_400_000),
        key: key
    )

    let unlockedIndex = try AutoFillCredentialIndexUnlocker().unlock(
        encryptedIndex,
        vaultID: "vault-1",
        keyIdentifier: "autofill-key-1",
        key: key
    )

    #expect(unlockedIndex.records(matchingServiceIdentifier: "https://github.com/session").map(\.id) == ["entry-1"])
    #expect(unlockedIndex.records(matchingServiceIdentifier: "accounts.appleid.apple.com").map(\.id) == ["entry-2"])
    #expect(unlockedIndex.search("alice").map(\.id) == ["entry-1"])
    #expect(unlockedIndex.search("apple").map(\.id) == ["entry-2"])
    #expect(unlockedIndex.search("example.com").map(\.id) == ["entry-1", "entry-2"])
}

@Test func autoFillCredentialSecretCodecEncryptsAndDecryptsFillableSecrets() throws {
    let codec = AutoFillCredentialSecretCodec()
    let key = try AutoFillIndexEncryptionKey(rawValue: Data(repeating: 23, count: 32))
    let secrets = [
        AutoFillCredentialSecretRecord(
            id: "entry-1",
            username: "alice@example.com",
            password: "correct horse battery staple"
        )
    ]

    let snapshot = try codec.encrypt(
        secrets,
        vaultID: "vault-1",
        keyIdentifier: "autofill-key-1",
        updatedAt: Date(timeIntervalSince1970: 1_800_600_000),
        key: key
    )
    let unlockedSnapshot = try AutoFillCredentialSecretUnlocker().unlock(
        snapshot,
        vaultID: "vault-1",
        keyIdentifier: "autofill-key-1",
        key: key
    )

    #expect(snapshot.vaultID == "vault-1")
    #expect(snapshot.keyIdentifier == "autofill-key-1")
    #expect(snapshot.records.count == 1)
    #expect(unlockedSnapshot.secret(id: "entry-1") == secrets.first)
}

@Test func autoFillCredentialSecretStoreDoesNotContainPlaintextCredentialSecrets() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = FileAutoFillCredentialSecretStore(appGroupContainerURL: directory)
    let key = try AutoFillIndexEncryptionKey(rawValue: Data(repeating: 29, count: 32))
    let snapshot = try AutoFillCredentialSecretCodec().encrypt(
        [
            AutoFillCredentialSecretRecord(
                id: "entry-1",
                username: "alice@example.com",
                password: "correct horse battery staple"
            )
        ],
        vaultID: "vault-1",
        keyIdentifier: "autofill-key-1",
        updatedAt: Date(timeIntervalSince1970: 1_800_600_000),
        key: key
    )

    try store.save(snapshot)

    let loaded = try #require(try store.load())
    let rawSnapshot = try String(contentsOf: store.secretFileURL, encoding: .utf8)
    #expect(loaded.records.map(\.id) == ["entry-1"])
    #expect(!rawSnapshot.contains("alice@example.com"))
    #expect(!rawSnapshot.contains("correct horse battery staple"))
}

@Test func autoFillCredentialResolverMatchesDomainsAndDeduplicatesRecords() {
    let resolver = AutoFillCredentialResolver(
        index: AutoFillUnlockedCredentialIndex(
            vaultID: "vault-1",
            keyIdentifier: "autofill-key-1",
            updatedAt: Date(timeIntervalSince1970: 1_800_800_000),
            records: [
                AutoFillCredentialIndexRecord(
                    id: "entry-1",
                    title: "GitHub",
                    username: "alice@example.com",
                    serviceIdentifiers: ["github.com", "https://github.com/login"]
                ),
                AutoFillCredentialIndexRecord(
                    id: "entry-2",
                    title: "Apple ID",
                    username: "bob@example.com",
                    serviceIdentifiers: ["appleid.apple.com"]
                )
            ]
        ),
        secrets: AutoFillUnlockedCredentialSecretSnapshot(
            vaultID: "vault-1",
            keyIdentifier: "autofill-key-1",
            updatedAt: Date(timeIntervalSince1970: 1_800_800_000),
            records: []
        )
    )

    let records = resolver.records(
        matchingServiceIdentifiers: [
            "https://github.com/session",
            "github.com"
        ]
    )

    #expect(records.map(\.id) == ["entry-1"])
}

@Test func autoFillCredentialResolverSearchesOnlyWithinMatchedRecords() {
    let matchedRecords = [
        AutoFillCredentialIndexRecord(
            id: "entry-1",
            title: "GitHub",
            username: "alice@example.com",
            serviceIdentifiers: ["github.com"]
        )
    ]
    let resolver = AutoFillCredentialResolver(
        index: AutoFillUnlockedCredentialIndex(
            vaultID: "vault-1",
            keyIdentifier: "autofill-key-1",
            updatedAt: Date(timeIntervalSince1970: 1_800_800_000),
            records: matchedRecords + [
                AutoFillCredentialIndexRecord(
                    id: "entry-2",
                    title: "Apple ID",
                    username: "bob@example.com",
                    serviceIdentifiers: ["appleid.apple.com"]
                )
            ]
        ),
        secrets: AutoFillUnlockedCredentialSecretSnapshot(
            vaultID: "vault-1",
            keyIdentifier: "autofill-key-1",
            updatedAt: Date(timeIntervalSince1970: 1_800_800_000),
            records: []
        )
    )

    #expect(resolver.search("alice", within: matchedRecords).map(\.id) == ["entry-1"])
    #expect(resolver.search("apple", within: matchedRecords).isEmpty)
    #expect(resolver.search("   ", within: matchedRecords).map(\.id) == ["entry-1"])
}

@Test func autoFillCredentialResolverReturnsFillableSecretForSelectedRecordIdentifier() throws {
    let resolver = AutoFillCredentialResolver(
        index: AutoFillUnlockedCredentialIndex(
            vaultID: "vault-1",
            keyIdentifier: "autofill-key-1",
            updatedAt: Date(timeIntervalSince1970: 1_800_800_000),
            records: [
                AutoFillCredentialIndexRecord(
                    id: "entry-1",
                    title: "GitHub",
                    username: "alice@example.com",
                    serviceIdentifiers: ["github.com"]
                )
            ]
        ),
        secrets: AutoFillUnlockedCredentialSecretSnapshot(
            vaultID: "vault-1",
            keyIdentifier: "autofill-key-1",
            updatedAt: Date(timeIntervalSince1970: 1_800_800_000),
            records: [
                AutoFillCredentialSecretRecord(
                    id: "entry-1",
                    username: "alice@example.com",
                    password: "correct horse battery staple"
                )
            ]
        )
    )

    #expect(
        try resolver.credential(recordIdentifier: "entry-1")
            == AutoFillCredentialSecretRecord(
                id: "entry-1",
                username: "alice@example.com",
                password: "correct horse battery staple"
            )
    )
    #expect(throws: AutoFillCredentialResolverError.credentialUnavailable) {
        try resolver.credential(recordIdentifier: "missing")
    }
}

private final class RecordingVaultEngine: LocalVaultEngine {
    private(set) var createdVaults: [RecordedVaultCall] = []
    private(set) var openedVaults: [RecordedVaultCall] = []
    private(set) var securityKeyOpenedVaults: [RecordedSecurityKeyVaultCall] = []
    private(set) var securityKeySetups: [RecordedSecurityKeySetupCall] = []
    private(set) var resetMasterPasswordCalls: [RecordedResetMasterPasswordCall] = []
    private(set) var createdProjects: [RecordedProjectCall] = []
    private(set) var renamedProjects: [RecordedRenamedProjectCall] = []
    private(set) var deletedProjects: [RecordedDeletedProjectCall] = []
    private(set) var movedVaultEntries: [RecordedMoveEntryCall] = []
    private(set) var createdLoginEntries: [RecordedLoginEntryCall] = []
    private(set) var updatedLoginEntries: [RecordedUpdatedLoginEntryCall] = []
    private(set) var favoritedLoginEntries: [RecordedFavoriteEntryCall] = []
    private(set) var favoritedNoteEntries: [RecordedFavoriteEntryCall] = []
    private(set) var favoritedTotpEntries: [RecordedFavoriteEntryCall] = []
    private(set) var favoritedCardEntries: [RecordedFavoriteEntryCall] = []
    private(set) var favoritedIdentityEntries: [RecordedFavoriteEntryCall] = []
    private(set) var favoritedPasskeyEntries: [RecordedFavoriteEntryCall] = []
    private(set) var favoritedSshKeyEntries: [RecordedFavoriteEntryCall] = []
    private(set) var favoritedApiTokenEntries: [RecordedFavoriteEntryCall] = []
    private(set) var favoritedWifiEntries: [RecordedFavoriteEntryCall] = []
    private(set) var favoritedSendEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedLoginEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredLoginEntries: [RecordedEntryMutationCall] = []
    private(set) var createdNoteEntries: [RecordedNoteEntryCall] = []
    private(set) var updatedNoteEntries: [RecordedUpdatedNoteEntryCall] = []
    private(set) var deletedNoteEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredNoteEntries: [RecordedEntryMutationCall] = []
    private(set) var createdTotpEntries: [RecordedTotpEntryCall] = []
    private(set) var updatedTotpEntries: [RecordedUpdatedTotpEntryCall] = []
    private(set) var deletedTotpEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredTotpEntries: [RecordedEntryMutationCall] = []
    private(set) var createdCardEntries: [RecordedCardEntryCall] = []
    private(set) var updatedCardEntries: [RecordedUpdatedCardEntryCall] = []
    private(set) var deletedCardEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredCardEntries: [RecordedEntryMutationCall] = []
    private(set) var createdIdentityEntries: [RecordedIdentityEntryCall] = []
    private(set) var updatedIdentityEntries: [RecordedUpdatedIdentityEntryCall] = []
    private(set) var deletedIdentityEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredIdentityEntries: [RecordedEntryMutationCall] = []
    private(set) var createdPasskeyEntries: [RecordedPasskeyEntryCall] = []
    private(set) var updatedPasskeyEntries: [RecordedUpdatedPasskeyEntryCall] = []
    private(set) var deletedPasskeyEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredPasskeyEntries: [RecordedEntryMutationCall] = []
    private(set) var createdSshKeyEntries: [RecordedSshKeyEntryCall] = []
    private(set) var updatedSshKeyEntries: [RecordedUpdatedSshKeyEntryCall] = []
    private(set) var deletedSshKeyEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredSshKeyEntries: [RecordedEntryMutationCall] = []
    private(set) var createdApiTokenEntries: [RecordedApiTokenEntryCall] = []
    private(set) var updatedApiTokenEntries: [RecordedUpdatedApiTokenEntryCall] = []
    private(set) var deletedApiTokenEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredApiTokenEntries: [RecordedEntryMutationCall] = []
    private(set) var createdWifiEntries: [RecordedWifiEntryCall] = []
    private(set) var updatedWifiEntries: [RecordedUpdatedWifiEntryCall] = []
    private(set) var deletedWifiEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredWifiEntries: [RecordedEntryMutationCall] = []
    private(set) var createdSendEntries: [RecordedSendEntryCall] = []
    private(set) var updatedSendEntries: [RecordedUpdatedSendEntryCall] = []
    private(set) var deletedSendEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredSendEntries: [RecordedEntryMutationCall] = []
    private(set) var createdAttachmentMetadata: [RecordedAttachmentMetadataCall] = []
    private(set) var deletedAttachmentMetadata: [RecordedAttachmentMutationCall] = []
    private(set) var restoredAttachmentMetadata: [RecordedAttachmentMutationCall] = []
    private var projects: [String: [LocalVaultProject]] = [:]
    private var loginEntries: [String: [LocalLoginEntry]] = [:]
    private var deletedEntries: [String: [LocalLoginEntry]] = [:]
    private var noteEntries: [String: [LocalNoteEntry]] = [:]
    private var deletedNotes: [String: [LocalNoteEntry]] = [:]
    private var totpEntries: [String: [LocalTotpEntry]] = [:]
    private var deletedTotp: [String: [LocalTotpEntry]] = [:]
    private var cardEntries: [String: [LocalCardEntry]] = [:]
    private var deletedCards: [String: [LocalCardEntry]] = [:]
    private var identityEntries: [String: [LocalIdentityEntry]] = [:]
    private var deletedIdentities: [String: [LocalIdentityEntry]] = [:]
    private var passkeyEntries: [String: [LocalPasskeyEntry]] = [:]
    private var deletedPasskeys: [String: [LocalPasskeyEntry]] = [:]
    private var sshKeyEntries: [String: [LocalSshKeyEntry]] = [:]
    private var deletedSshKeys: [String: [LocalSshKeyEntry]] = [:]
    private var apiTokenEntries: [String: [LocalApiTokenEntry]] = [:]
    private var deletedApiTokens: [String: [LocalApiTokenEntry]] = [:]
    private var wifiEntries: [String: [LocalWifiEntry]] = [:]
    private var deletedWifi: [String: [LocalWifiEntry]] = [:]
    private var sendEntries: [String: [LocalSendEntry]] = [:]
    private var deletedSend: [String: [LocalSendEntry]] = [:]
    private var attachmentMetadata: [String: [LocalAttachmentMetadata]] = [:]
    private var deletedAttachments: [String: [LocalAttachmentMetadata]] = [:]

    func createVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle {
        createdVaults.append(.init(fileURL: fileURL, password: password, deviceID: deviceID))
        return LocalVaultHandle(vaultID: "created-vault", deviceID: deviceID)
    }

    func openVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle {
        openedVaults.append(.init(fileURL: fileURL, password: password, deviceID: deviceID))
        return LocalVaultHandle(vaultID: "opened-vault", deviceID: deviceID)
    }

    func openVaultWithSecurityKey(
        at fileURL: URL,
        securityKeyMaterial: Data,
        deviceID: String
    ) throws -> LocalVaultHandle {
        securityKeyOpenedVaults.append(
            .init(fileURL: fileURL, keyMaterial: securityKeyMaterial, deviceID: deviceID)
        )
        return LocalVaultHandle(vaultID: "security-key-opened-vault", deviceID: deviceID)
    }

    func setupLocalSecurityKeyUnlock(
        in handle: LocalVaultHandle,
        securityKeyMaterial: Data
    ) throws {
        securityKeySetups.append(
            .init(vaultID: handle.vaultID, keyMaterial: securityKeyMaterial)
        )
    }

    func resetMasterPassword(
        in handle: LocalVaultHandle,
        newPassword: String
    ) throws {
        resetMasterPasswordCalls.append(
            .init(vaultID: handle.vaultID, newPassword: newPassword)
        )
    }

    func closeVault(_ handle: LocalVaultHandle) {}

    func createProject(
        in handle: LocalVaultHandle,
        title: String
    ) throws -> LocalVaultProject {
        createdProjects.append(.init(vaultID: handle.vaultID, title: title))
        let project = LocalVaultProject(id: "project-\(createdProjects.count)", title: title)
        projects[handle.vaultID, default: []].append(project)
        return project
    }

    func listProjects(in handle: LocalVaultHandle) throws -> [LocalVaultProject] {
        projects[handle.vaultID, default: []]
    }

    func renameProject(
        in handle: LocalVaultHandle,
        projectID: String,
        title: String
    ) throws -> LocalVaultProject {
        guard let index = projects[handle.vaultID, default: []].firstIndex(where: { $0.id == projectID }) else {
            throw LocalVaultRepositoryError.projectNotFound
        }
        let renamed = LocalVaultProject(id: projectID, title: title)
        renamedProjects.append(.init(vaultID: handle.vaultID, projectID: projectID, title: title))
        projects[handle.vaultID, default: []][index] = renamed
        return renamed
    }

    func deleteProject(in handle: LocalVaultHandle, projectID: String) throws {
        guard projects[handle.vaultID, default: []].contains(where: { $0.id == projectID }) else {
            throw LocalVaultRepositoryError.projectNotFound
        }
        guard !projectContainsEntries(projectID: projectID) else {
            throw LocalVaultRepositoryError.projectNotEmpty
        }
        deletedProjects.append(.init(vaultID: handle.vaultID, projectID: projectID))
        projects[handle.vaultID, default: []].removeAll { $0.id == projectID }
    }

    func moveEntry(
        in handle: LocalVaultHandle,
        kind: UnifiedVaultItemKind,
        entryID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws -> LocalVaultMovedEntry {
        movedVaultEntries.append(
            .init(
                vaultID: handle.vaultID,
                kind: kind,
                entryID: entryID,
                fromProjectID: fromProjectID,
                toProjectID: toProjectID
            )
        )

        switch kind {
        case .login:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &loginEntries, title: \.title) { entry, projectID in
                LocalLoginEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    username: entry.username,
                    password: entry.password,
                    url: entry.url,
                    favorite: entry.favorite
                )
            }
        case .note:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &noteEntries, title: \.title) { entry, projectID in
                LocalNoteEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    body: entry.body,
                    favorite: entry.favorite
                )
            }
        case .totp:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &totpEntries, title: \.title) { entry, projectID in
                LocalTotpEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    secret: entry.secret,
                    issuer: entry.issuer,
                    accountName: entry.accountName,
                    period: entry.period,
                    digits: entry.digits,
                    algorithm: entry.algorithm,
                    otpType: entry.otpType,
                    counter: entry.counter,
                    favorite: entry.favorite
                )
            }
        case .card:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &cardEntries, title: \.title) { entry, projectID in
                LocalCardEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    cardholderName: entry.cardholderName,
                    number: entry.number,
                    expiryMonth: entry.expiryMonth,
                    expiryYear: entry.expiryYear,
                    cvv: entry.cvv,
                    issuer: entry.issuer,
                    network: entry.network,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .identity:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &identityEntries, title: \.title) { entry, projectID in
                LocalIdentityEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    documentType: entry.documentType,
                    fullName: entry.fullName,
                    documentNumber: entry.documentNumber,
                    issuer: entry.issuer,
                    country: entry.country,
                    issueDate: entry.issueDate,
                    expiryDate: entry.expiryDate,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .passkey:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &passkeyEntries, title: \.title) { entry, projectID in
                LocalPasskeyEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    relyingPartyID: entry.relyingPartyID,
                    username: entry.username,
                    userHandle: entry.userHandle,
                    credentialID: entry.credentialID,
                    publicKeyCOSE: entry.publicKeyCOSE,
                    privateKeyReference: entry.privateKeyReference,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .sshKey:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &sshKeyEntries, title: \.title) { entry, projectID in
                LocalSshKeyEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    username: entry.username,
                    host: entry.host,
                    publicKey: entry.publicKey,
                    privateKeyReference: entry.privateKeyReference,
                    passphraseHint: entry.passphraseHint,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .apiToken:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &apiTokenEntries, title: \.title) { entry, projectID in
                LocalApiTokenEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    issuer: entry.issuer,
                    accountName: entry.accountName,
                    token: entry.token,
                    scopes: entry.scopes,
                    expiresAt: entry.expiresAt,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .wifi:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &wifiEntries, title: \.title) { entry, projectID in
                LocalWifiEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    ssid: entry.ssid,
                    securityType: entry.securityType,
                    password: entry.password,
                    hidden: entry.hidden,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .send:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &sendEntries, title: \.title) { entry, projectID in
                LocalSendEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    body: entry.body,
                    expiresAt: entry.expiresAt,
                    maxViews: entry.maxViews,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .attachmentRef:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &attachmentMetadata, title: \.fileName) { entry, projectID in
                LocalAttachmentMetadata(
                    id: entry.id,
                    projectID: projectID,
                    entryID: entry.entryID,
                    fileName: entry.fileName,
                    mediaType: entry.mediaType,
                    originalSize: entry.originalSize,
                    storedSize: entry.storedSize,
                    contentHash: entry.contentHash,
                    storageMode: entry.storageMode,
                    source: entry.source,
                    downloadState: entry.downloadState,
                    wrappedContentEncryptionKey: entry.wrappedContentEncryptionKey,
                    localPath: entry.localPath,
                    deleted: entry.deleted
                )
            }
        }
    }

    private func moveRecordedEntry<Entry: Identifiable>(
        entryID: String,
        fromProjectID: String,
        toProjectID: String,
        kind: UnifiedVaultItemKind,
        entries: inout [String: [Entry]],
        title: KeyPath<Entry, String>,
        moving: (Entry, String) -> Entry
    ) throws -> LocalVaultMovedEntry where Entry.ID == String {
        guard var sourceEntries = entries[fromProjectID],
              let index = sourceEntries.firstIndex(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let entry = sourceEntries.remove(at: index)
        entries[fromProjectID] = sourceEntries
        let moved = moving(entry, toProjectID)
        entries[toProjectID, default: []].append(moved)
        return LocalVaultMovedEntry(id: moved.id, title: moved[keyPath: title], kind: kind)
    }

    func createLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let entry = LocalLoginEntry(
            id: "entry-\(createdLoginEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            username: draft.username,
            password: draft.password,
            url: draft.url,
            notes: draft.notes
        )
        createdLoginEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        loginEntries[projectID, default: []].append(entry)
        return entry
    }

    func listLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry] {
        loginEntries[projectID, default: []]
    }

    func updateLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let entry = LocalLoginEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            username: draft.username,
            password: draft.password,
            url: draft.url,
            notes: draft.notes
        )
        updatedLoginEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        loginEntries[projectID, default: []] = loginEntries[projectID, default: []].map {
            $0.id == entryID ? entry : $0
        }
        return entry
    }

    func setLoginEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalLoginEntry {
        favoritedLoginEntries.append(
            .init(
                vaultID: handle.vaultID,
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
        )
        guard let current = loginEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let entry = LocalLoginEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            username: current.username,
            password: current.password,
            url: current.url,
            notes: current.notes,
            favorite: favorite
        )
        loginEntries[projectID, default: []] = loginEntries[projectID, default: []].map {
            $0.id == entryID ? entry : $0
        }
        return entry
    }

    func deleteLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedLoginEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = loginEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        loginEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedEntries[projectID, default: []].append(entry)
    }

    func listDeletedLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry] {
        deletedEntries[projectID, default: []]
    }

    func restoreLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalLoginEntry {
        restoredLoginEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedEntries[projectID, default: []].removeAll { $0.id == entryID }
        loginEntries[projectID, default: []].append(entry)
        return entry
    }

    func createNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let entry = LocalNoteEntry(
            id: "note-\(createdNoteEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            body: draft.body
        )
        createdNoteEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        noteEntries[projectID, default: []].append(entry)
        return entry
    }

    func listNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry] {
        noteEntries[projectID, default: []]
    }

    func updateNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let currentFavorite = noteEntries[projectID, default: []]
            .first { $0.id == entryID }?
            .favorite ?? false
        let entry = LocalNoteEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            body: draft.body,
            favorite: currentFavorite
        )
        updatedNoteEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        noteEntries[projectID, default: []] = noteEntries[projectID, default: []].map {
            $0.id == entryID ? entry : $0
        }
        return entry
    }

    func setNoteEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalNoteEntry {
        favoritedNoteEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite)
        )
        guard let current = noteEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let entry = LocalNoteEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            body: current.body,
            favorite: favorite
        )
        noteEntries[projectID, default: []] = noteEntries[projectID, default: []].map {
            $0.id == entryID ? entry : $0
        }
        return entry
    }

    func deleteNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedNoteEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = noteEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        noteEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedNotes[projectID, default: []].append(entry)
    }

    func listDeletedNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry] {
        deletedNotes[projectID, default: []]
    }

    func restoreNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalNoteEntry {
        restoredNoteEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedNotes[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedNotes[projectID, default: []].removeAll { $0.id == entryID }
        noteEntries[projectID, default: []].append(entry)
        return entry
    }

    func createTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let entry = LocalTotpEntry(
            id: "totp-\(createdTotpEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            secret: draft.secret,
            issuer: draft.issuer,
            accountName: draft.accountName,
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm,
            otpType: draft.otpType,
            counter: draft.counter
        )
        createdTotpEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        totpEntries[projectID, default: []].append(entry)
        return entry
    }

    func listTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry] {
        totpEntries[projectID, default: []]
    }

    func updateTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let currentFavorite = totpEntries[projectID, default: []]
            .first { $0.id == entryID }?
            .favorite ?? false
        let entry = LocalTotpEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            secret: draft.secret,
            issuer: draft.issuer,
            accountName: draft.accountName,
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm,
            otpType: draft.otpType,
            counter: draft.counter,
            favorite: currentFavorite
        )
        updatedTotpEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        totpEntries[projectID, default: []] = totpEntries[projectID, default: []].map {
            $0.id == entryID ? entry : $0
        }
        return entry
    }

    func setTotpEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalTotpEntry {
        favoritedTotpEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite)
        )
        guard let current = totpEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let entry = LocalTotpEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            secret: current.secret,
            issuer: current.issuer,
            accountName: current.accountName,
            period: current.period,
            digits: current.digits,
            algorithm: current.algorithm,
            otpType: current.otpType,
            counter: current.counter,
            favorite: favorite
        )
        totpEntries[projectID, default: []] = totpEntries[projectID, default: []].map {
            $0.id == entryID ? entry : $0
        }
        return entry
    }

    func deleteTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedTotpEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = totpEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        totpEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedTotp[projectID, default: []].append(entry)
    }

    func listDeletedTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry] {
        deletedTotp[projectID, default: []]
    }

    func restoreTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalTotpEntry {
        restoredTotpEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedTotp[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedTotp[projectID, default: []].removeAll { $0.id == entryID }
        totpEntries[projectID, default: []].append(entry)
        return entry
    }

    func createCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let entry = LocalCardEntry(
            id: "card-\(createdCardEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            cardholderName: draft.cardholderName,
            number: draft.number,
            expiryMonth: draft.expiryMonth,
            expiryYear: draft.expiryYear,
            cvv: draft.cvv,
            issuer: draft.issuer,
            network: draft.network,
            notes: draft.notes
        )
        createdCardEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        cardEntries[projectID, default: []].append(entry)
        return entry
    }

    func listCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry] {
        cardEntries[projectID, default: []]
    }

    func updateCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let currentFavorite = cardEntries[projectID, default: []]
            .first { $0.id == entryID }?
            .favorite ?? false
        let entry = LocalCardEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            cardholderName: draft.cardholderName,
            number: draft.number,
            expiryMonth: draft.expiryMonth,
            expiryYear: draft.expiryYear,
            cvv: draft.cvv,
            issuer: draft.issuer,
            network: draft.network,
            notes: draft.notes,
            favorite: currentFavorite
        )
        updatedCardEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        cardEntries[projectID, default: []] = cardEntries[projectID, default: []].map {
            $0.id == entryID ? entry : $0
        }
        return entry
    }

    func setCardEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalCardEntry {
        favoritedCardEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite)
        )
        guard let current = cardEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let entry = LocalCardEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            cardholderName: current.cardholderName,
            number: current.number,
            expiryMonth: current.expiryMonth,
            expiryYear: current.expiryYear,
            cvv: current.cvv,
            issuer: current.issuer,
            network: current.network,
            notes: current.notes,
            favorite: favorite
        )
        cardEntries[projectID, default: []] = cardEntries[projectID, default: []].map {
            $0.id == entryID ? entry : $0
        }
        return entry
    }

    func deleteCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedCardEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = cardEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        cardEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedCards[projectID, default: []].append(entry)
    }

    func listDeletedCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry] {
        deletedCards[projectID, default: []]
    }

    func restoreCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalCardEntry {
        restoredCardEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedCards[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedCards[projectID, default: []].removeAll { $0.id == entryID }
        cardEntries[projectID, default: []].append(entry)
        return entry
    }

    func createIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let entry = LocalIdentityEntry(
            id: "identity-\(createdIdentityEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes
        )
        createdIdentityEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        identityEntries[projectID, default: []].append(entry)
        return entry
    }

    func listIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry] {
        identityEntries[projectID, default: []]
    }

    func updateIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let currentFavorite = identityEntries[projectID, default: []]
            .first { $0.id == entryID }?
            .favorite ?? false
        let entry = LocalIdentityEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes,
            favorite: currentFavorite
        )
        updatedIdentityEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        identityEntries[projectID, default: []] = identityEntries[projectID, default: []].map {
            $0.id == entryID ? entry : $0
        }
        return entry
    }

    func setIdentityEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalIdentityEntry {
        favoritedIdentityEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite)
        )
        guard let current = identityEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let entry = LocalIdentityEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            documentType: current.documentType,
            fullName: current.fullName,
            documentNumber: current.documentNumber,
            issuer: current.issuer,
            country: current.country,
            issueDate: current.issueDate,
            expiryDate: current.expiryDate,
            notes: current.notes,
            favorite: favorite
        )
        identityEntries[projectID, default: []] = identityEntries[projectID, default: []].map {
            $0.id == entryID ? entry : $0
        }
        return entry
    }

    func deleteIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedIdentityEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = identityEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        identityEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedIdentities[projectID, default: []].append(entry)
    }

    func listDeletedIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry] {
        deletedIdentities[projectID, default: []]
    }

    func restoreIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalIdentityEntry {
        restoredIdentityEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedIdentities[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedIdentities[projectID, default: []].removeAll { $0.id == entryID }
        identityEntries[projectID, default: []].append(entry)
        return entry
    }

    func createPasskeyEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry {
        let entry = LocalPasskeyEntry(id: "passkey-\(createdPasskeyEntries.count + 1)", projectID: projectID, title: draft.title, relyingPartyID: draft.relyingPartyID, username: draft.username, userHandle: draft.userHandle, credentialID: draft.credentialID, publicKeyCOSE: draft.publicKeyCOSE, privateKeyReference: draft.privateKeyReference, notes: draft.notes)
        createdPasskeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, draft: draft))
        passkeyEntries[projectID, default: []].append(entry)
        return entry
    }

    func listPasskeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPasskeyEntry] {
        passkeyEntries[projectID, default: []]
    }

    func updatePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry {
        let favorite = passkeyEntries[projectID, default: []].first { $0.id == entryID }?.favorite ?? false
        let entry = LocalPasskeyEntry(id: entryID, projectID: projectID, title: draft.title, relyingPartyID: draft.relyingPartyID, username: draft.username, userHandle: draft.userHandle, credentialID: draft.credentialID, publicKeyCOSE: draft.publicKeyCOSE, privateKeyReference: draft.privateKeyReference, notes: draft.notes, favorite: favorite)
        updatedPasskeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft))
        passkeyEntries[projectID, default: []] = passkeyEntries[projectID, default: []].map { $0.id == entryID ? entry : $0 }
        return entry
    }

    func setPasskeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalPasskeyEntry {
        favoritedPasskeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite))
        guard let current = passkeyEntries[projectID, default: []].first(where: { $0.id == entryID }) else { throw LocalVaultRepositoryError.vaultUnavailable }
        let entry = LocalPasskeyEntry(id: current.id, projectID: current.projectID, title: current.title, relyingPartyID: current.relyingPartyID, username: current.username, userHandle: current.userHandle, credentialID: current.credentialID, publicKeyCOSE: current.publicKeyCOSE, privateKeyReference: current.privateKeyReference, notes: current.notes, favorite: favorite)
        passkeyEntries[projectID, default: []] = passkeyEntries[projectID, default: []].map { $0.id == entryID ? entry : $0 }
        return entry
    }

    func deletePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        deletedPasskeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = passkeyEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        passkeyEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedPasskeys[projectID, default: []].append(entry)
    }

    func listDeletedPasskeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPasskeyEntry] {
        deletedPasskeys[projectID, default: []]
    }

    func restorePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalPasskeyEntry {
        restoredPasskeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = deletedPasskeys[projectID, default: []].first(where: { $0.id == entryID }) else { throw LocalVaultRepositoryError.vaultUnavailable }
        deletedPasskeys[projectID, default: []].removeAll { $0.id == entryID }
        passkeyEntries[projectID, default: []].append(entry)
        return entry
    }

    func createSshKeyEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        let entry = LocalSshKeyEntry(id: "ssh-\(createdSshKeyEntries.count + 1)", projectID: projectID, title: draft.title, username: draft.username, host: draft.host, publicKey: draft.publicKey, privateKeyReference: draft.privateKeyReference, passphraseHint: draft.passphraseHint, notes: draft.notes)
        createdSshKeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, draft: draft))
        sshKeyEntries[projectID, default: []].append(entry)
        return entry
    }

    func listSshKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSshKeyEntry] {
        sshKeyEntries[projectID, default: []]
    }

    func updateSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        let favorite = sshKeyEntries[projectID, default: []].first { $0.id == entryID }?.favorite ?? false
        let entry = LocalSshKeyEntry(id: entryID, projectID: projectID, title: draft.title, username: draft.username, host: draft.host, publicKey: draft.publicKey, privateKeyReference: draft.privateKeyReference, passphraseHint: draft.passphraseHint, notes: draft.notes, favorite: favorite)
        updatedSshKeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft))
        sshKeyEntries[projectID, default: []] = sshKeyEntries[projectID, default: []].map { $0.id == entryID ? entry : $0 }
        return entry
    }

    func setSshKeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSshKeyEntry {
        favoritedSshKeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite))
        guard let current = sshKeyEntries[projectID, default: []].first(where: { $0.id == entryID }) else { throw LocalVaultRepositoryError.vaultUnavailable }
        let entry = LocalSshKeyEntry(id: current.id, projectID: current.projectID, title: current.title, username: current.username, host: current.host, publicKey: current.publicKey, privateKeyReference: current.privateKeyReference, passphraseHint: current.passphraseHint, notes: current.notes, favorite: favorite)
        sshKeyEntries[projectID, default: []] = sshKeyEntries[projectID, default: []].map { $0.id == entryID ? entry : $0 }
        return entry
    }

    func deleteSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        deletedSshKeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = sshKeyEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        sshKeyEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedSshKeys[projectID, default: []].append(entry)
    }

    func listDeletedSshKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSshKeyEntry] {
        deletedSshKeys[projectID, default: []]
    }

    func restoreSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSshKeyEntry {
        restoredSshKeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = deletedSshKeys[projectID, default: []].first(where: { $0.id == entryID }) else { throw LocalVaultRepositoryError.vaultUnavailable }
        deletedSshKeys[projectID, default: []].removeAll { $0.id == entryID }
        sshKeyEntries[projectID, default: []].append(entry)
        return entry
    }

    func createApiTokenEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        let entry = LocalApiTokenEntry(id: "api-token-\(createdApiTokenEntries.count + 1)", projectID: projectID, title: draft.title, issuer: draft.issuer, accountName: draft.accountName, token: draft.token, scopes: draft.scopes, expiresAt: draft.expiresAt, notes: draft.notes)
        createdApiTokenEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, draft: draft))
        apiTokenEntries[projectID, default: []].append(entry)
        return entry
    }

    func listApiTokenEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalApiTokenEntry] {
        apiTokenEntries[projectID, default: []]
    }

    func updateApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        let favorite = apiTokenEntries[projectID, default: []].first { $0.id == entryID }?.favorite ?? false
        let entry = LocalApiTokenEntry(id: entryID, projectID: projectID, title: draft.title, issuer: draft.issuer, accountName: draft.accountName, token: draft.token, scopes: draft.scopes, expiresAt: draft.expiresAt, notes: draft.notes, favorite: favorite)
        updatedApiTokenEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft))
        apiTokenEntries[projectID, default: []] = apiTokenEntries[projectID, default: []].map { $0.id == entryID ? entry : $0 }
        return entry
    }

    func setApiTokenEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalApiTokenEntry {
        favoritedApiTokenEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite))
        guard let current = apiTokenEntries[projectID, default: []].first(where: { $0.id == entryID }) else { throw LocalVaultRepositoryError.vaultUnavailable }
        let entry = LocalApiTokenEntry(id: current.id, projectID: current.projectID, title: current.title, issuer: current.issuer, accountName: current.accountName, token: current.token, scopes: current.scopes, expiresAt: current.expiresAt, notes: current.notes, favorite: favorite)
        apiTokenEntries[projectID, default: []] = apiTokenEntries[projectID, default: []].map { $0.id == entryID ? entry : $0 }
        return entry
    }

    func deleteApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        deletedApiTokenEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = apiTokenEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        apiTokenEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedApiTokens[projectID, default: []].append(entry)
    }

    func listDeletedApiTokenEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalApiTokenEntry] {
        deletedApiTokens[projectID, default: []]
    }

    func restoreApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalApiTokenEntry {
        restoredApiTokenEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = deletedApiTokens[projectID, default: []].first(where: { $0.id == entryID }) else { throw LocalVaultRepositoryError.vaultUnavailable }
        deletedApiTokens[projectID, default: []].removeAll { $0.id == entryID }
        apiTokenEntries[projectID, default: []].append(entry)
        return entry
    }

    func createWifiEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        let entry = LocalWifiEntry(id: "wifi-\(createdWifiEntries.count + 1)", projectID: projectID, title: draft.title, ssid: draft.ssid, securityType: draft.securityType, password: draft.password, hidden: draft.hidden, notes: draft.notes)
        createdWifiEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, draft: draft))
        wifiEntries[projectID, default: []].append(entry)
        return entry
    }

    func listWifiEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalWifiEntry] {
        wifiEntries[projectID, default: []]
    }

    func updateWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        let favorite = wifiEntries[projectID, default: []].first { $0.id == entryID }?.favorite ?? false
        let entry = LocalWifiEntry(id: entryID, projectID: projectID, title: draft.title, ssid: draft.ssid, securityType: draft.securityType, password: draft.password, hidden: draft.hidden, notes: draft.notes, favorite: favorite)
        updatedWifiEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft))
        wifiEntries[projectID, default: []] = wifiEntries[projectID, default: []].map { $0.id == entryID ? entry : $0 }
        return entry
    }

    func setWifiEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalWifiEntry {
        favoritedWifiEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite))
        guard let current = wifiEntries[projectID, default: []].first(where: { $0.id == entryID }) else { throw LocalVaultRepositoryError.vaultUnavailable }
        let entry = LocalWifiEntry(id: current.id, projectID: current.projectID, title: current.title, ssid: current.ssid, securityType: current.securityType, password: current.password, hidden: current.hidden, notes: current.notes, favorite: favorite)
        wifiEntries[projectID, default: []] = wifiEntries[projectID, default: []].map { $0.id == entryID ? entry : $0 }
        return entry
    }

    func deleteWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        deletedWifiEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = wifiEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        wifiEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedWifi[projectID, default: []].append(entry)
    }

    func listDeletedWifiEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalWifiEntry] {
        deletedWifi[projectID, default: []]
    }

    func restoreWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalWifiEntry {
        restoredWifiEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = deletedWifi[projectID, default: []].first(where: { $0.id == entryID }) else { throw LocalVaultRepositoryError.vaultUnavailable }
        deletedWifi[projectID, default: []].removeAll { $0.id == entryID }
        wifiEntries[projectID, default: []].append(entry)
        return entry
    }

    func createSendEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry {
        let entry = LocalSendEntry(id: "send-\(createdSendEntries.count + 1)", projectID: projectID, title: draft.title, body: draft.body, expiresAt: draft.expiresAt, maxViews: draft.maxViews, notes: draft.notes)
        createdSendEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, draft: draft))
        sendEntries[projectID, default: []].append(entry)
        return entry
    }

    func listSendEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSendEntry] {
        sendEntries[projectID, default: []]
    }

    func updateSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry {
        let favorite = sendEntries[projectID, default: []].first { $0.id == entryID }?.favorite ?? false
        let entry = LocalSendEntry(id: entryID, projectID: projectID, title: draft.title, body: draft.body, expiresAt: draft.expiresAt, maxViews: draft.maxViews, notes: draft.notes, favorite: favorite)
        updatedSendEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft))
        sendEntries[projectID, default: []] = sendEntries[projectID, default: []].map { $0.id == entryID ? entry : $0 }
        return entry
    }

    func setSendEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSendEntry {
        favoritedSendEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite))
        guard let current = sendEntries[projectID, default: []].first(where: { $0.id == entryID }) else { throw LocalVaultRepositoryError.vaultUnavailable }
        let entry = LocalSendEntry(id: current.id, projectID: current.projectID, title: current.title, body: current.body, expiresAt: current.expiresAt, maxViews: current.maxViews, notes: current.notes, favorite: favorite)
        sendEntries[projectID, default: []] = sendEntries[projectID, default: []].map { $0.id == entryID ? entry : $0 }
        return entry
    }

    func deleteSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        deletedSendEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = sendEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        sendEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedSend[projectID, default: []].append(entry)
    }

    func listDeletedSendEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSendEntry] {
        deletedSend[projectID, default: []]
    }

    func restoreSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSendEntry {
        restoredSendEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = deletedSend[projectID, default: []].first(where: { $0.id == entryID }) else { throw LocalVaultRepositoryError.vaultUnavailable }
        deletedSend[projectID, default: []].removeAll { $0.id == entryID }
        sendEntries[projectID, default: []].append(entry)
        return entry
    }

    func createAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String,
        downloadState: String,
        wrappedContentEncryptionKey: String?,
        localPath: String?
    ) throws -> LocalAttachmentMetadata {
        let metadata = LocalAttachmentMetadata(
            id: "attachment-\(createdAttachmentMetadata.count + 1)",
            projectID: projectID,
            entryID: entryID,
            fileName: fileName,
            mediaType: mediaType,
            originalSize: originalSize,
            storedSize: storedSize,
            contentHash: contentHash,
            storageMode: storageMode,
            source: source,
            downloadState: downloadState,
            wrappedContentEncryptionKey: wrappedContentEncryptionKey,
            localPath: localPath,
            deleted: false
        )
        createdAttachmentMetadata.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, fileName: fileName, source: source, downloadState: downloadState, wrappedContentEncryptionKey: wrappedContentEncryptionKey, localPath: localPath))
        attachmentMetadata[projectID, default: []].append(metadata)
        return metadata
    }

    func listAttachmentMetadata(in handle: LocalVaultHandle, projectID: String) throws -> [LocalAttachmentMetadata] {
        attachmentMetadata[projectID, default: []]
    }

    func deleteAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String) throws {
        deletedAttachmentMetadata.append(.init(vaultID: handle.vaultID, projectID: projectID, attachmentID: attachmentID))
        guard let metadata = attachmentMetadata[projectID, default: []].first(where: { $0.id == attachmentID }) else { return }
        attachmentMetadata[projectID, default: []].removeAll { $0.id == attachmentID }
        deletedAttachments[projectID, default: []].append(LocalAttachmentMetadata(id: metadata.id, projectID: metadata.projectID, entryID: metadata.entryID, fileName: metadata.fileName, mediaType: metadata.mediaType, originalSize: metadata.originalSize, storedSize: metadata.storedSize, contentHash: metadata.contentHash, storageMode: metadata.storageMode, source: metadata.source, downloadState: metadata.downloadState, wrappedContentEncryptionKey: metadata.wrappedContentEncryptionKey, localPath: metadata.localPath, deleted: true))
    }

    func listDeletedAttachmentMetadata(in handle: LocalVaultHandle, projectID: String) throws -> [LocalAttachmentMetadata] {
        deletedAttachments[projectID, default: []]
    }

    func restoreAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String) throws -> LocalAttachmentMetadata {
        restoredAttachmentMetadata.append(.init(vaultID: handle.vaultID, projectID: projectID, attachmentID: attachmentID))
        guard let metadata = deletedAttachments[projectID, default: []].first(where: { $0.id == attachmentID }) else { throw LocalVaultRepositoryError.vaultUnavailable }
        let restored = LocalAttachmentMetadata(id: metadata.id, projectID: metadata.projectID, entryID: metadata.entryID, fileName: metadata.fileName, mediaType: metadata.mediaType, originalSize: metadata.originalSize, storedSize: metadata.storedSize, contentHash: metadata.contentHash, storageMode: metadata.storageMode, source: metadata.source, downloadState: metadata.downloadState, wrappedContentEncryptionKey: metadata.wrappedContentEncryptionKey, localPath: metadata.localPath, deleted: false)
        deletedAttachments[projectID, default: []].removeAll { $0.id == attachmentID }
        attachmentMetadata[projectID, default: []].append(restored)
        return restored
    }

    private func projectContainsEntries(projectID: String) -> Bool {
        !loginEntries[projectID, default: []].isEmpty
            || !deletedEntries[projectID, default: []].isEmpty
            || !noteEntries[projectID, default: []].isEmpty
            || !deletedNotes[projectID, default: []].isEmpty
            || !totpEntries[projectID, default: []].isEmpty
            || !deletedTotp[projectID, default: []].isEmpty
            || !cardEntries[projectID, default: []].isEmpty
            || !deletedCards[projectID, default: []].isEmpty
            || !identityEntries[projectID, default: []].isEmpty
            || !deletedIdentities[projectID, default: []].isEmpty
            || !passkeyEntries[projectID, default: []].isEmpty
            || !deletedPasskeys[projectID, default: []].isEmpty
            || !sshKeyEntries[projectID, default: []].isEmpty
            || !deletedSshKeys[projectID, default: []].isEmpty
            || !apiTokenEntries[projectID, default: []].isEmpty
            || !deletedApiTokens[projectID, default: []].isEmpty
            || !wifiEntries[projectID, default: []].isEmpty
            || !deletedWifi[projectID, default: []].isEmpty
            || !sendEntries[projectID, default: []].isEmpty
            || !deletedSend[projectID, default: []].isEmpty
            || !attachmentMetadata[projectID, default: []].isEmpty
            || !deletedAttachments[projectID, default: []].isEmpty
    }
}

private struct RecordedVaultCall: Equatable {
    let fileURL: URL
    let password: String
    let deviceID: String
}

private struct RecordedSecurityKeyVaultCall: Equatable {
    let fileURL: URL
    let keyMaterial: Data
    let deviceID: String
}

private struct RecordedSecurityKeySetupCall: Equatable {
    let vaultID: String
    let keyMaterial: Data
}

private struct RecordedResetMasterPasswordCall: Equatable {
    let vaultID: String
    let newPassword: String
}

private struct RecordedProjectCall: Equatable {
    let vaultID: String
    let title: String
}

private struct RecordedRenamedProjectCall: Equatable {
    let vaultID: String
    let projectID: String
    let title: String
}

private struct RecordedDeletedProjectCall: Equatable {
    let vaultID: String
    let projectID: String
}

private struct RecordedMoveEntryCall: Equatable {
    let vaultID: String
    let kind: UnifiedVaultItemKind
    let entryID: String
    let fromProjectID: String
    let toProjectID: String
}

private struct RecordedLoginEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let draft: LocalLoginEntryDraft
}

private struct RecordedUpdatedLoginEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalLoginEntryDraft
}

private struct RecordedFavoriteEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let entryID: String
    let favorite: Bool
}

private struct RecordedNoteEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let draft: LocalNoteEntryDraft
}

private struct RecordedUpdatedNoteEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalNoteEntryDraft
}

private struct RecordedTotpEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let draft: LocalTotpEntryDraft
}

private struct RecordedUpdatedTotpEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalTotpEntryDraft
}

private struct RecordedCardEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let draft: LocalCardEntryDraft
}

private struct RecordedUpdatedCardEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalCardEntryDraft
}

private struct RecordedIdentityEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let draft: LocalIdentityEntryDraft
}

private struct RecordedUpdatedIdentityEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalIdentityEntryDraft
}

private struct RecordedPasskeyEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let draft: LocalPasskeyEntryDraft
}

private struct RecordedUpdatedPasskeyEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalPasskeyEntryDraft
}

private struct RecordedSshKeyEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let draft: LocalSshKeyEntryDraft
}

private struct RecordedUpdatedSshKeyEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalSshKeyEntryDraft
}

private struct RecordedApiTokenEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let draft: LocalApiTokenEntryDraft
}

private struct RecordedUpdatedApiTokenEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalApiTokenEntryDraft
}

private struct RecordedWifiEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let draft: LocalWifiEntryDraft
}

private struct RecordedUpdatedWifiEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalWifiEntryDraft
}

private struct RecordedSendEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let draft: LocalSendEntryDraft
}

private struct RecordedUpdatedSendEntryCall: Equatable {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalSendEntryDraft
}

private struct RecordedAttachmentMetadataCall: Equatable {
    let vaultID: String
    let projectID: String
    let entryID: String?
    let fileName: String
    let source: String
    let downloadState: String
    let wrappedContentEncryptionKey: String?
    let localPath: String?
}

private struct RecordedEntryMutationCall: Equatable {
    let vaultID: String
    let projectID: String
    let entryID: String
}

private struct RecordedAttachmentMutationCall: Equatable {
    let vaultID: String
    let projectID: String
    let attachmentID: String
}

private func makeKdbx3Header(
    cipherID: Data,
    compressionFlags: Data,
    masterSeed: Data,
    transformSeed: Data,
    transformRounds: UInt64,
    encryptionIV: Data,
    protectedStreamKey: Data,
    streamStartBytes: Data,
    innerRandomStreamID: UInt32
) -> Data {
    var data = Data([
        0x03, 0xD9, 0xA2, 0x9A,
        0x67, 0xFB, 0x4B, 0xB5,
        0x01, 0x00, 0x03, 0x00
    ])
    data.append(kdbx3HeaderField(id: 2, value: cipherID))
    data.append(kdbx3HeaderField(id: 3, value: compressionFlags))
    data.append(kdbx3HeaderField(id: 4, value: masterSeed))
    data.append(kdbx3HeaderField(id: 5, value: transformSeed))
    data.append(kdbx3HeaderField(id: 6, value: littleEndianUInt64(transformRounds)))
    data.append(kdbx3HeaderField(id: 7, value: encryptionIV))
    data.append(kdbx3HeaderField(id: 8, value: protectedStreamKey))
    data.append(kdbx3HeaderField(id: 9, value: streamStartBytes))
    data.append(kdbx3HeaderField(id: 10, value: littleEndianUInt32(innerRandomStreamID)))
    data.append(kdbx3HeaderField(id: 0, value: Data([0x0D, 0x0A, 0x0D, 0x0A])))
    return data
}

private func kdbx3HeaderField(id: UInt8, value: Data) -> Data {
    var field = Data([id])
    var length = UInt16(value.count).littleEndian
    field.append(Data(bytes: &length, count: MemoryLayout<UInt16>.size))
    field.append(value)
    return field
}

private func makeKdbx4Header(
    cipherID: Data,
    compressionFlags: Data,
    masterSeed: Data? = nil,
    encryptionIV: Data? = nil,
    innerRandomStreamKey: Data? = nil,
    streamStartBytes: Data? = nil,
    innerRandomStreamID: UInt32? = nil,
    kdfParameters: Data
) -> Data {
    var data = Data([
        0x03, 0xD9, 0xA2, 0x9A,
        0x67, 0xFB, 0x4B, 0xB5,
        0x00, 0x00, 0x04, 0x00
    ])
    data.append(kdbx4HeaderField(id: 2, value: cipherID))
    data.append(kdbx4HeaderField(id: 3, value: compressionFlags))
    if let masterSeed {
        data.append(kdbx4HeaderField(id: 4, value: masterSeed))
    }
    if let encryptionIV {
        data.append(kdbx4HeaderField(id: 7, value: encryptionIV))
    }
    if let innerRandomStreamKey {
        data.append(kdbx4HeaderField(id: 8, value: innerRandomStreamKey))
    }
    if let streamStartBytes {
        data.append(kdbx4HeaderField(id: 9, value: streamStartBytes))
    }
    if let innerRandomStreamID {
        data.append(kdbx4HeaderField(id: 10, value: littleEndianUInt32(innerRandomStreamID)))
    }
    data.append(kdbx4HeaderField(id: 11, value: kdfParameters))
    data.append(kdbx4HeaderField(id: 0, value: Data([0x0D, 0x0A, 0x0D, 0x0A])))
    return data
}

private func kdbx4HeaderField(id: UInt8, value: Data) -> Data {
    var field = Data([id])
    field.append(littleEndianUInt32(UInt32(value.count)))
    field.append(value)
    return field
}

private func makeKdbxVariantDictionary(uuid: Data) -> Data {
    makeKdbxVariantDictionary(entries: [
        kdbxVariantByteArray(key: "$UUID", value: uuid)
    ])
}

private func makeKdbx3HashedBlockStream(streamStartBytes: Data, blocks: [Data]) -> Data {
    var data = Data()
    data.append(streamStartBytes)
    for (index, block) in blocks.enumerated() {
        data.append(littleEndianUInt32(UInt32(index)))
        data.append(Data(SHA256.hash(data: block)))
        data.append(littleEndianUInt32(UInt32(block.count)))
        data.append(block)
    }
    data.append(littleEndianUInt32(UInt32(blocks.count)))
    data.append(Data(repeating: 0x00, count: 32))
    data.append(littleEndianUInt32(0))
    return data
}

private func makeKdbx4HmacBlockStream(hmacBaseKey: Data, blocks: [Data]) -> Data {
    var data = Data()
    for (index, block) in blocks.enumerated() {
        data.append(kdbx4BlockHmac(blockIndex: UInt64(index), block: block, hmacBaseKey: hmacBaseKey))
        data.append(littleEndianUInt32(UInt32(block.count)))
        data.append(block)
    }
    let terminator = Data()
    data.append(kdbx4BlockHmac(blockIndex: UInt64(blocks.count), block: terminator, hmacBaseKey: hmacBaseKey))
    data.append(littleEndianUInt32(0))
    return data
}

private func makeKdbx4InnerHeader(fields: [(UInt8, Data)]) -> Data {
    var data = Data()
    for (id, value) in fields {
        data.append(id)
        data.append(littleEndianUInt32(UInt32(value.count)))
        data.append(value)
    }
    data.append(0)
    data.append(littleEndianUInt32(0))
    return data
}

private func makeKdbx4PayloadSection(hmacBaseKey: Data, blocks: [Data]) -> Data {
    var data = Data()
    data.append(Data(repeating: 0x00, count: SHA256.byteCount))
    data.append(Data(repeating: 0x11, count: SHA256.byteCount))
    data.append(makeKdbx4HmacBlockStream(hmacBaseKey: hmacBaseKey, blocks: blocks))
    return data
}

private func kdbx4HeaderHmac(headerBytes: Data, hmacBaseKey: Data) -> Data {
    let headerKey = SymmetricKey(data: Data(SHA512.hash(data: littleEndianUInt64(UInt64.max) + hmacBaseKey)))
    return Data(HMAC<SHA256>.authenticationCode(for: headerBytes, using: headerKey))
}

private func kdbx4BlockHmac(blockIndex: UInt64, block: Data, hmacBaseKey: Data) -> Data {
    let blockKeyInput = littleEndianUInt64(blockIndex) + hmacBaseKey
    let blockKey = SymmetricKey(data: Data(SHA512.hash(data: blockKeyInput)))
    var blockMacInput = Data()
    blockMacInput.append(littleEndianUInt64(blockIndex))
    blockMacInput.append(littleEndianUInt32(UInt32(block.count)))
    blockMacInput.append(block)
    return Data(HMAC<SHA256>.authenticationCode(for: blockMacInput, using: blockKey))
}

private func makeKdbxVariantDictionary(entries: [Data]) -> Data {
    var data = Data([0x00, 0x01])
    for entry in entries {
        data.append(entry)
    }
    data.append(Data([0x00]))
    return data
}

private func kdbxVariantByteArray(key: String, value: Data) -> Data {
    var data = Data([0x42])
    let keyData = Data(key.utf8)
    data.append(littleEndianUInt32(UInt32(keyData.count)))
    data.append(keyData)
    data.append(littleEndianUInt32(UInt32(value.count)))
    data.append(value)
    return data
}

private func kdbxVariantUInt32(key: String, value: UInt32) -> Data {
    var data = Data([0x04])
    let keyData = Data(key.utf8)
    data.append(littleEndianUInt32(UInt32(keyData.count)))
    data.append(keyData)
    data.append(littleEndianUInt32(UInt32(MemoryLayout<UInt32>.size)))
    data.append(littleEndianUInt32(value))
    return data
}

private func kdbxVariantUInt64(key: String, value: UInt64) -> Data {
    var data = Data([0x05])
    let keyData = Data(key.utf8)
    data.append(littleEndianUInt32(UInt32(keyData.count)))
    data.append(keyData)
    data.append(littleEndianUInt32(UInt32(MemoryLayout<UInt64>.size)))
    data.append(littleEndianUInt64(value))
    return data
}

private func decodeHexData(_ value: String) throws -> Data {
    let compactValue = String(value.filter { !$0.isWhitespace })
    guard compactValue.count.isMultiple(of: 2),
          compactValue.allSatisfy(\.isHexDigit) else {
        throw KeePassOperationError(code: .formatUnsupported, message: "invalid test hex")
    }
    var data = Data()
    var index = compactValue.startIndex
    while index < compactValue.endIndex {
        let next = compactValue.index(index, offsetBy: 2)
        guard let byte = UInt8(compactValue[index..<next], radix: 16) else {
            throw KeePassOperationError(code: .formatUnsupported, message: "invalid test hex")
        }
        data.append(byte)
        index = next
    }
    return data
}

private func littleEndianUInt32(_ value: UInt32) -> Data {
    var little = value.littleEndian
    return Data(bytes: &little, count: MemoryLayout<UInt32>.size)
}

private func littleEndianUInt64(_ value: UInt64) -> Data {
    var little = value.littleEndian
    return Data(bytes: &little, count: MemoryLayout<UInt64>.size)
}
