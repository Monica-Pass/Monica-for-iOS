import Foundation
import Testing
@testable import MonicaSecurity

@Suite("密保答案凭据")
struct SecurityQuestionAnswerCredentialTests {
    private func fastHasher(
        saltByteCount: Int = 16
    ) -> SecurityQuestionAnswerHasher {
        SecurityQuestionAnswerHasher(
            parameters: .argon2id(
                timeCost: 1,
                memoryKiB: 1024,
                parallelism: 1,
                saltByteCount: saltByteCount
            )
        )
    }

    private func bytes(_ range: Range<Int>) -> Data {
        Data(range.map { UInt8($0) })
    }

    @Test func normalizationCollapsesWhitespaceCaseAndUnicode() {
        #expect(SecurityQuestionAnswerNormalizer.normalized("  Tokyo  ") == "tokyo")
        #expect(SecurityQuestionAnswerNormalizer.normalized("TOKYO") == "tokyo")
        #expect(SecurityQuestionAnswerNormalizer.normalized("  tokyo \n\t blue  ") == "tokyo blue")
        #expect(
            SecurityQuestionAnswerNormalizer.normalized("To\u{0304}kyo\u{0304}")
                == SecurityQuestionAnswerNormalizer.normalized("Tōkyō")
        )
        #expect(SecurityQuestionAnswerNormalizer.legacyNormalized("  Tokyo  ") == "tokyo")
    }

    @Test func sameAnswerProducesIndependentSaltAndDigest() throws {
        let verifier = SecurityQuestionAnswerVerifier(hasher: fastHasher())
        let first = try verifier.makeCredential(for: "Tokyo")
        let second = try verifier.makeCredential(for: "Tokyo")

        #expect(first != second)
        guard case .kdf(let firstRecord) = first, case .kdf(let secondRecord) = second else {
            Issue.record("新记录必须使用 KDF 凭据。")
            return
        }
        #expect(firstRecord.salt != secondRecord.salt)
        #expect(firstRecord.digest != secondRecord.digest)
        #expect(firstRecord.salt.count >= SecurityQuestionKDFParameters.minimumSaltByteCount)
        #expect(firstRecord.digest.count == SecurityQuestionAnswerRecord.digestByteCount)
        #expect(verifier.verify("  tokyo ", against: first) == .matched(needsUpgrade: false))
        #expect(verifier.verify("Osaka", against: first) == .mismatched)
    }

    @Test func argon2idMatchesCrossImplementationVector() throws {
        let parameters = SecurityQuestionKDFParameters.argon2id(
            timeCost: 2,
            memoryKiB: 1024,
            parallelism: 1,
            saltByteCount: 16
        )
        let hasher = SecurityQuestionAnswerHasher(
            parameters: parameters,
            saltGenerator: { _ in self.bytes(0..<16) }
        )
        let verifier = SecurityQuestionAnswerVerifier(hasher: hasher)

        let record = try hasher.makeRecord(for: "tokyo")
        #expect(
            SecurityQuestionHex.encode(record.digest)
                == "587bbec6388afa1a87c2654f2278fa18ffd9d6c082003606ec892fe1f58cb091"
        )
        #expect(verifier.verify("TOKYO", against: record) == .matched(needsUpgrade: false))

        let unicodeRecord = try hasher.makeRecord(for: "密保答案")
        #expect(
            SecurityQuestionHex.encode(unicodeRecord.digest)
                == "6920a2dbe5336e4e02eee61627e83e177e4e5c47b5defe5d8d07d3f7e7a2b294"
        )
    }

    @Test func pbkdf2MatchesReferenceVectors() throws {
        let one = try SecurityQuestionAnswerHasher.pbkdf2SHA256(
            password: Data("password".utf8),
            salt: Data("salt".utf8),
            iterations: 1,
            outputByteCount: 32
        )
        #expect(
            SecurityQuestionHex.encode(one)
                == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
        )

        let fourThousand = try SecurityQuestionAnswerHasher.pbkdf2SHA256(
            password: Data("password".utf8),
            salt: Data("salt".utf8),
            iterations: 4096,
            outputByteCount: 32
        )
        #expect(
            SecurityQuestionHex.encode(fourThousand)
                == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"
        )

        let unicode = try SecurityQuestionAnswerHasher.pbkdf2SHA256(
            password: Data("密保答案".utf8),
            salt: bytes(0..<16),
            iterations: 4096,
            outputByteCount: 32
        )
        #expect(
            SecurityQuestionHex.encode(unicode)
                == "d0f4b3deeafa851614f8052398cb81fdfc1d68b0a7bd99c7271b43b8035a9eda"
        )
    }

    @Test func legacyCredentialUsesLegacyNormalization() {
        let credential = SecurityQuestionAnswerCredential.legacyUnsaltedSHA256(
            hexDigest: "AFE04579004049CCCE1843A40BDF9EB85F3A4839390375E35D0018A7F9AA70C8"
        )
        let verifier = SecurityQuestionAnswerVerifier()

        #expect(credential.isLegacy)
        #expect(verifier.verify(" TOKYO ", against: credential) == .legacyMatched)
        #expect(verifier.verify("tokyo", against: credential) == .legacyMatched)
        #expect(verifier.verify("tokyo blue", against: credential) == .mismatched)
        #expect(
            SecurityQuestionAnswerVerifier.legacySHA256Hex(for: "Tokyo")
                == "afe04579004049ccce1843a40bdf9eb85f3a4839390375e35d0018a7f9aa70c8"
        )
    }

    @Test func invalidRecordsAreRejectedWithoutThrowing() {
        let verifier = SecurityQuestionAnswerVerifier()
        let salt = Data(repeating: 1, count: 16)
        let digest = Data(repeating: 2, count: 32)

        let futureVersion = SecurityQuestionAnswerRecord(
            schemaVersion: 2,
            algorithm: .argon2id,
            parameters: .default,
            salt: salt,
            digest: digest
        )
        guard case .invalidRecord(let versionReason) = verifier.verify("tokyo", against: futureVersion) else {
            Issue.record("未来版本的记录应被标记为无效。")
            return
        }
        #expect(versionReason.contains("版本"))

        let shortSaltParameters = SecurityQuestionKDFParameters.pbkdf2SHA256(
            iterations: 1_000,
            saltByteCount: 8
        )
        let shortSalt = SecurityQuestionAnswerRecord(
            algorithm: .pbkdf2SHA256,
            parameters: shortSaltParameters,
            salt: Data(repeating: 1, count: 8),
            digest: digest
        )
        #expect(verifier.verify("tokyo", against: shortSalt).isMatch == false)

        let oversizedMemory = SecurityQuestionKDFParameters.argon2id(memoryKiB: 4 * 1024 * 1024)
        let oversized = SecurityQuestionAnswerRecord(
            algorithm: .argon2id,
            parameters: oversizedMemory,
            salt: salt,
            digest: digest
        )
        guard case .invalidRecord(let memoryReason) = verifier.verify("tokyo", against: oversized) else {
            Issue.record("超出边界的内存成本应被拒绝。")
            return
        }
        #expect(memoryReason.contains("内存"))

        let shortDigest = SecurityQuestionAnswerRecord(
            algorithm: .argon2id,
            parameters: .default,
            salt: salt,
            digest: Data(repeating: 2, count: 16)
        )
        #expect(verifier.verify("tokyo", against: shortDigest).isMatch == false)
    }

    @Test func storedRecordDecodingMapsCorruptionToRecoverableError() {
        do {
            _ = try KeychainSecurityQuestionRecoveryStore.decodeStoredSetup(Data("not-json".utf8))
            Issue.record("损坏的 JSON 应抛出 corruptedStoredRecord。")
        } catch let error as SecurityQuestionCredentialError {
            #expect(error == .corruptedStoredRecord)
        } catch {
            Issue.record("意外错误：\(error)")
        }
    }

    @Test func throttleEscalatesLocksAndResets() {
        let throttle = SecurityQuestionVerificationThrottle(
            freeAttempts: 2,
            initialLockout: 60,
            maximumLockout: 900
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var state = SecurityQuestionVerificationThrottle.State()

        state = throttle.stateAfterFailure(state: state, now: start)
        #expect(state.failureCount == 1)
        #expect(throttle.remainingLockout(state: state, now: start) == 0)

        state = throttle.stateAfterFailure(state: state, now: start)
        #expect(state.failureCount == 2)
        #expect(throttle.remainingLockout(state: state, now: start) == 0)

        state = throttle.stateAfterFailure(state: state, now: start)
        #expect(state.failureCount == 3)
        #expect(throttle.remainingLockout(state: state, now: start) == 60)

        state = throttle.stateAfterFailure(state: state, now: start.addingTimeInterval(61))
        #expect(state.failureCount == 4)
        #expect(throttle.remainingLockout(state: state, now: start.addingTimeInterval(61)) == 120)

        state = throttle.stateAfterFailure(state: state, now: start.addingTimeInterval(1_000))
        #expect(throttle.remainingLockout(state: state, now: start.addingTimeInterval(1_000)) == 240)

        state = throttle.stateAfterFailure(state: state, now: start.addingTimeInterval(10_000))
        #expect(throttle.remainingLockout(state: state, now: start.addingTimeInterval(10_000)) == 480)

        state = throttle.stateAfterFailure(state: state, now: start.addingTimeInterval(20_000))
        #expect(throttle.remainingLockout(state: state, now: start.addingTimeInterval(20_000)) == 900)

        state = throttle.stateAfterFailure(state: state, now: start.addingTimeInterval(30_000))
        #expect(throttle.remainingLockout(state: state, now: start.addingTimeInterval(30_000)) == 900)

        #expect(throttle.remainingLockout(state: state, now: start.addingTimeInterval(60_000)) == 0)
        #expect(throttle.stateAfterSuccess() == .clear)
    }

    @Test func encodedCredentialContainsOnlyDerivedMaterial() throws {
        let verifier = SecurityQuestionAnswerVerifier(hasher: fastHasher())
        let credential = try verifier.makeCredential(for: "SuperSecretAnswer")
        let data = try JSONEncoder().encode(credential)
        let json = String(decoding: data, as: UTF8.self)

        #expect(!json.lowercased().contains("supersecretanswer"))
        #expect(json.contains("\"salt\""))
        #expect(json.contains("\"digest\""))
        #expect(try JSONDecoder().decode(SecurityQuestionAnswerCredential.self, from: data) == credential)
    }

    @Test func migratingStorePrefersPrimaryAndClearsLegacyOnSave() throws {
        let suiteName = "monica.tests.security-questions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacy = UserDefaultsLegacySecurityQuestionRecoveryStore(userDefaults: defaults)
        let primary = MemorySecurityQuestionRecoveryStore()
        let store = MigratingSecurityQuestionRecoveryStore(primary: primary, legacy: legacy)
        let legacyPayload: [String: Any] = [
            "vaultID": "vault-1",
            "question1ID": 1,
            "question1Text": "第一题",
            "answer1Hash": SecurityQuestionAnswerVerifier.legacySHA256Hex(for: "tokyo"),
            "question2ID": 3,
            "question2Text": "第二题",
            "answer2Hash": SecurityQuestionAnswerVerifier.legacySHA256Hex(for: "blue")
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: legacyPayload),
            forKey: UserDefaultsLegacySecurityQuestionRecoveryStore.keyPrefix + "vault-1"
        )

        let loaded = try store.load(vaultID: "vault-1")
        #expect(loaded?.containsLegacyAnswers == true)
        #expect(
            loaded?.answer1
                == .legacyUnsaltedSHA256(
                    hexDigest: SecurityQuestionAnswerVerifier.legacySHA256Hex(for: "tokyo")
                )
        )

        let verifier = SecurityQuestionAnswerVerifier(hasher: fastHasher())
        let upgradedSetup = SecurityQuestionRecoverySetup(
            vaultID: "vault-1",
            question1ID: 1,
            question1Text: "第一题",
            answer1: try verifier.makeCredential(for: "tokyo"),
            question2ID: 3,
            question2Text: "第二题",
            answer2: try verifier.makeCredential(for: "blue")
        )
        try store.save(upgradedSetup)

        #expect(try legacy.load(vaultID: "vault-1") == nil)
        #expect(try store.load(vaultID: "vault-1") == upgradedSetup)
    }

    @Test func upgradedSetupRehashesOnlyLegacySide() throws {
        let verifier = SecurityQuestionAnswerVerifier(hasher: fastHasher())
        let legacyCredential = SecurityQuestionAnswerCredential.legacyUnsaltedSHA256(
            hexDigest: SecurityQuestionAnswerVerifier.legacySHA256Hex(for: "tokyo")
        )
        let currentCredential = try verifier.makeCredential(for: "blue")
        let setup = SecurityQuestionRecoverySetup(
            vaultID: "vault-1",
            question1ID: 1,
            question1Text: "第一题",
            answer1: legacyCredential,
            question2ID: 3,
            question2Text: "第二题",
            answer2: currentCredential
        )
        let verdict1 = verifier.verify("tokyo", against: legacyCredential)
        let verdict2 = verifier.verify("blue", against: currentCredential)
        #expect(verdict1 == .legacyMatched)
        #expect(verdict2 == .matched(needsUpgrade: false))

        let upgraded = try verifier.upgradedSetup(
            for: setup,
            answer1: "tokyo",
            answer2: "blue",
            verdict1: verdict1,
            verdict2: verdict2
        )
        #expect(upgraded?.answer1 != legacyCredential)
        #expect(upgraded?.answer2 == currentCredential)
        #expect(upgraded?.containsLegacyAnswers == false)
        #expect(
            try verifier.upgradedSetup(
                for: setup.replacingAnswers(
                    answer1: try verifier.makeCredential(for: "tokyo"),
                    answer2: currentCredential
                ),
                answer1: "tokyo",
                answer2: "blue",
                verdict1: .matched(needsUpgrade: false),
                verdict2: .matched(needsUpgrade: false)
            ) == nil
        )
    }

    @Test func weakerRecordsReportUpgradeNeeded() throws {
        let weakHasher = SecurityQuestionAnswerHasher(
            parameters: .pbkdf2SHA256(iterations: 1_000)
        )
        let strongVerifier = SecurityQuestionAnswerVerifier()
        let weakCredential = try weakHasher.makeCredential(for: "tokyo")
        guard case .kdf(let weakRecord) = weakCredential else {
            Issue.record("弱参数凭据也应使用 KDF 记录。")
            return
        }

        #expect(strongVerifier.verify("tokyo", against: weakCredential) == .matched(needsUpgrade: true))
        #expect(strongVerifier.hasher.needsUpgrade(weakRecord))
    }

    @Test func defaultParametersAreWithinProductionBounds() throws {
        try SecurityQuestionAnswerHasher().validateParameters()
        #expect(SecurityQuestionKDFParameters.default.saltByteCount >= 16)
        #expect(
            SecurityQuestionKDFParameters.default.memoryKiB
                == SecurityQuestionKDFParameters.defaultArgon2MemoryKiB
        )
    }
}
