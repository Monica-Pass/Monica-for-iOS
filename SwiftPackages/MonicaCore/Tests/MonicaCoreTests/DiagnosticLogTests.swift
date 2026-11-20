import Foundation
import Testing
@testable import MonicaCore

// MARK: - Fixtures that must never survive into an export

private enum SecretFixture {
    static let password = "correct-horse-battery-staple"
    static let totpCode = "123456"
    static let token = "eyJhbGciOiJIUzI1NiJ9.token-secret-value"
    static let clientDataHashBase64 = "3q2+7w1B2c3D4e5F6g7H8i9J0kLmnopqrstu=="
    static let clientDataHashHex = "9f2c7d1e8b3a40516f7e8d9c0b1a2f3e4d5c6b7a8f9e0d1c2b3a4f5e6d7c8b9a"
    static let querySecret = "code=\(totpCode)&access_token=\(token)"

    static var all: [String] {
        [password, totpCode, token, clientDataHashBase64, clientDataHashHex]
    }
}

private func makeLog(
    capacity: Int = 500,
    minimumLevel: DiagnosticLevel = .debug,
    includesHostNames: Bool = true
) -> DiagnosticLog {
    DiagnosticLog(
        configuration: .init(
            capacity: capacity,
            minimumLevel: minimumLevel,
            includesHostNames: includesHostNames,
            mirrorsToSystemLog: false
        )
    )
}

// MARK: - Export contains no injected secret

@Test func exportedReportContainsNoInjectedSecretFixture() throws {
    let log = makeLog()
    let now = Date()

    // Push every string-bearing fixture through every builder that could carry text.
    let hostileURL = URL(string: "https://alice:\(SecretFixture.password)@sync.example.com/vault?\(SecretFixture.querySecret)#\(SecretFixture.clientDataHashBase64)")!
    log.record(
        .cloudSyncNetworkFailure,
        level: .error,
        module: .cloudSync,
        metadata: .merged(
            .flow(UUID()),
            .provider(.oneDrive),
            .stage(.download),
            .reason(.network),
            .status(403),
            .host(of: hostileURL),
            .artifact(.vaultFile)
        ),
        at: now
    )
    log.record(
        .passkeyInvalidClientDataHash,
        level: .error,
        module: .passkey,
        metadata: .merged(
            .reason(.invalidInput),
            .artifact(.database)
        ),
        at: now
    )
    log.record(
        .oneDriveSignInFailed,
        level: .warning,
        module: .oneDriveAuth,
        metadata: .merged(
            .status(Int(SecretFixture.totpCode)!),
            .artifact(.manifest)
        ),
        at: now
    )

    let report = try log.exportReport(minimumLevel: .debug, vaultIsUnlocked: true, generatedAt: now)

    #expect(SecretFixture.all.filter(report.contains) == [])
    #expect(!report.contains("alice"))
    #expect(!report.contains("access_token"))
    #expect(!report.contains("?"))

    // The safe parts did survive, so the assertions above are not vacuous.
    #expect(report.contains("host=sync.example.com"))
    #expect(report.contains("SYNC-1022"))
    #expect(report.contains("PASS-3011"))
    #expect(report.contains("AUTH-2001"))
    #expect(report.contains("status=403"))
}

@Test func urlMetadataKeepsOnlyTheDnsHost() {
    let url = URL(string: "https://user:\(SecretFixture.password)@Sync.Example.com./deep/path?token=\(SecretFixture.token)")!
    let metadata = DiagnosticMetadata.host(of: url)
    #expect(metadata.renderedFields == "host=sync.example.com")

    let invalid = DiagnosticMetadata.host(of: URL(string: "https://\(SecretFixture.password)_token/path"))
    #expect(invalid.isEmpty)

    #expect(DiagnosticMetadata.host(of: nil).isEmpty)
}

@Test func fileMetadataOnlyAcceptsTheClosedArtifactSet() {
    #expect(DiagnosticMetadata.artifact(.vaultFile).renderedFields == "file=vault.mdbx")
    #expect(DiagnosticMetadata.artifact(.manifest).renderedFields == "file=manifest.json")
    // There is no builder that takes an arbitrary path or file name, so a
    // secret cannot be smuggled into the file field at all; every artifact is
    // a compile-time constant.
    #expect(DiagnosticArtifact.allCases.allSatisfy { artifact in
        !SecretFixture.all.contains { artifact.rawValue.contains($0) }
    })
}

@Test func outOfRangeNumbersAreDroppedInsteadOfClamped() {
    #expect(DiagnosticMetadata.status(999_999).isEmpty)
    #expect(DiagnosticMetadata.status(-500).renderedFields == "status=-500")
    #expect(DiagnosticMetadata.count(-1).isEmpty)
    #expect(DiagnosticMetadata.bytes(-4).isEmpty)
    #expect(DiagnosticMetadata.duration(milliseconds: -1).isEmpty)
}

@Test func disablingHostNamesScrubsStoredEvents() throws {
    let log = makeLog()
    let url = URL(string: "https://sync.example.com/vault")!
    log.record(.cloudSyncCheckStarted, level: .info, module: .cloudSync, metadata: .host(of: url).merging(.provider(.webDAV)))
    #expect(try log.events(vaultIsUnlocked: true).first?.metadata.renderedFields == "provider=webDAV host=sync.example.com")

    log.setIncludesHostNames(false)
    let events = try log.events(vaultIsUnlocked: true)
    #expect(events.first?.metadata.renderedFields == "provider=webDAV")

    log.record(.cloudSyncCheckStarted, level: .info, module: .cloudSync, metadata: .host(of: url))
    #expect(try log.events(vaultIsUnlocked: true).last?.metadata.isEmpty == true)
}

// MARK: - Bounded ring buffer

@Test func thousandWritesNeverGrowPastCapacity() throws {
    let log = makeLog(capacity: 50)
    let start = Date()
    for index in 0..<1_200 {
        log.record(
            .cloudSyncCheckStarted,
            level: .info,
            module: .cloudSync,
            metadata: .count(index),
            at: start.addingTimeInterval(TimeInterval(index))
        )
        #expect(log.count <= 50)
    }
    let events = try log.events(vaultIsUnlocked: true)
    #expect(events.count == 50)
    #expect(events.first?.metadata.value(for: .count) == .number(1_150))
    #expect(events.last?.metadata.value(for: .count) == .number(1_199))
}

@Test func defaultCapacityIsFiveHundred() throws {
    let log = DiagnosticLog(configuration: .init(mirrorsToSystemLog: false))
    #expect(log.capacity == 500)
    for index in 0..<1_001 {
        log.record(.cloudSyncOperationFinished, level: .info, module: .cloudSync, metadata: .count(index))
    }
    #expect(log.count == 500)
    #expect(try log.events(vaultIsUnlocked: true).count == 500)
}

@Test func eventsOlderThanTheRetentionWindowAreEvicted() throws {
    let log = makeLog()
    let now = Date()
    log.record(.vaultOpenStarted, level: .info, module: .vault, at: now.addingTimeInterval(-8 * 24 * 60 * 60))
    log.record(.vaultOpenStarted, level: .info, module: .vault, at: now.addingTimeInterval(-6 * 24 * 60 * 60))
    let events = try log.events(vaultIsUnlocked: true, now: now)
    #expect(events.count == 1)
    #expect(log.retention == 7 * 24 * 60 * 60)
}

// MARK: - Detailed logging off by default

@Test func detailedLoggingIsOffByDefaultAndDebugEventsAreDropped() throws {
    let log = DiagnosticLog(configuration: .init(mirrorsToSystemLog: false))
    #expect(log.minimumLevel == .info)
    #expect(log.isDetailedLoggingEnabled == false)

    let kept = log.record(.cloudSyncDownloadStarted, level: .debug, module: .cloudSync)
    #expect(kept == false)
    #expect(log.count == 0)

    #expect(log.record(.cloudSyncDownloadStarted, level: .info, module: .cloudSync))
    #expect(log.count == 1)

    log.setMinimumLevel(.debug)
    #expect(log.isDetailedLoggingEnabled)
    #expect(log.record(.cloudSyncDownloadStarted, level: .debug, module: .cloudSync))
}

// MARK: - Locked vault blocks browsing and export

@Test func lockedVaultBlocksBrowsingAndExport() throws {
    let log = makeLog()
    log.record(.vaultOpenFailed, level: .error, module: .vault)

    #expect(throws: DiagnosticAccessError.vaultLocked) {
        _ = try log.events(vaultIsUnlocked: false)
    }
    #expect(throws: DiagnosticAccessError.vaultLocked) {
        _ = try log.exportReport(vaultIsUnlocked: false)
    }

    // Clearing and recording stay available while locked: they only remove or
    // add local data, and a failed unlock must still be recordable.
    log.clear()
    #expect(log.count == 0)
    #expect(log.record(.vaultOpenFailed, level: .error, module: .vault))
}

// MARK: - Export header

@Test func exportHeaderStatesMetadataContentAndLocalOnlyOrigin() throws {
    let log = makeLog()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    log.record(.diagnosticsExported, level: .info, module: .diagnostics, at: now)

    let report = try log.exportReport(minimumLevel: .info, vaultIsUnlocked: true, generatedAt: now)
    #expect(report.contains("# Monica 诊断日志 v1"))
    #expect(report.contains("# 生成时间: 2023-11-14T22:13:20.000Z"))
    #expect(report.contains("# 条目: 1/500"))
    #expect(report.contains("# 保留窗口: 7 天"))
    #expect(report.contains("不含密码、验证码、令牌、密钥或完整 URL"))
    #expect(report.contains("不会自动上传"))
    #expect(report.contains("2023-11-14T22:13:20.000Z\tinfo\tdiagnostics\tDIAG-0004"))

    let empty = try makeLog().exportReport(vaultIsUnlocked: true, generatedAt: now)
    #expect(empty.contains("# 暂无事件"))
}

// MARK: - Extension spool

@Test func spoolRoundTripsStructuredEventsAndTruncates() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let spool = DiagnosticEventSpool(fileURL: directory.appendingPathComponent("diag.jsonl"))

    let flow = UUID()
    #expect(spool.append(DiagnosticEvent(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        level: .error,
        module: .passkey,
        code: .passkeyRegistrationFailed,
        metadata: .flow(flow).merging(.stage(.register), .reason(.keychain), .status(-25_293))
    )))
    #expect(spool.append(DiagnosticEvent(
        timestamp: Date(timeIntervalSince1970: 1_700_000_001),
        level: .info,
        module: .passkey,
        code: .passkeyRegistrationSucceeded
    )))

    let drained = spool.drain()
    #expect(drained.count == 2)
    #expect(drained.first?.metadata.value(for: .flow) == .token(flow))
    #expect(drained.first?.metadata.value(for: .status) == .number(-25_293))
    #expect(spool.drain().isEmpty)
}

@Test func spoolRejectsTamperedAndGarbageLines() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("diag.jsonl")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let valid = DiagnosticEventSpool.encode(DiagnosticEvent(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        level: .info,
        module: .passkey,
        code: .passkeyAssertionStarted,
        metadata: .host(of: URL(string: "https://safe.example.com")!)
    ))!
    // A tampered line: the host field carries a secret-bearing string.
    let tampered = valid.replacingOccurrences(
        of: "safe.example.com",
        with: "user:\(SecretFixture.password)@evil.example.com"
    )
    try Data((valid + "{not json}\n" + tampered).utf8).write(to: fileURL)

    let spool = DiagnosticEventSpool(fileURL: fileURL)
    let drained = spool.drain()
    #expect(drained.count == 2)
    #expect(drained[0].metadata.value(for: .host) == .host("safe.example.com"))
    #expect(drained[1].metadata.value(for: .host) == nil)
}

@Test func spoolKeepsAtMostTheMaximumNumberOfLines() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("diag.jsonl")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var payload = ""
    for index in 0..<10 {
        payload += DiagnosticEventSpool.encode(DiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
            level: .info,
            module: .passkey,
            code: .passkeyAssertionStarted
        ))!
    }
    try Data(payload.utf8).write(to: fileURL)

    let spool = DiagnosticEventSpool(fileURL: fileURL, maximumEvents: 3, maximumBytes: 1024 * 1024)
    spool.trimToCapacity()
    let drained = spool.drain()
    #expect(drained.count == 3)
    #expect(drained.last?.timestamp == Date(timeIntervalSince1970: 1_700_000_009))
}

// MARK: - Seven taps

@Test func developerModeUnlocksOnTheSeventhTapWithinTheWindow() {
    var tracker = DeveloperModeUnlockTracker()
    let start = Date()
    for tap in 0..<6 {
        let unlocked = tracker.registerTap(at: start.addingTimeInterval(TimeInterval(tap) * 0.2))
        #expect(unlocked == false)
        #expect(tracker.remainingTapCount == 6 - tap)
    }
    #expect(tracker.registerTap(at: start.addingTimeInterval(1.2)) == true)
    #expect(tracker.tapCount == 0)
}

@Test func developerModeResetsAfterAPause() {
    var tracker = DeveloperModeUnlockTracker()
    let start = Date()
    for tap in 0..<6 {
        tracker.registerTap(at: start.addingTimeInterval(TimeInterval(tap) * 0.2))
    }
    // Six taps, then a pause longer than the window: the count restarts.
    let afterPause = tracker.registerTap(at: start.addingTimeInterval(30))
    #expect(afterPause == false)
    #expect(tracker.tapCount == 1)
    #expect(tracker.remainingTapCount == 6)
}

// MARK: - Passkey error mapping

@Test func passkeyErrorsMapToStableCodesWithoutPayload() {
    #expect(PasskeyCredentialError.invalidRelyingPartyID.diagnosticCode == .passkeyInvalidRelyingPartyID)
    #expect(PasskeyCredentialError.invalidClientDataHashLength.diagnosticCode == .passkeyInvalidClientDataHash)
    #expect(PasskeyCredentialError.invalidUsername.diagnosticCode == .passkeyInvalidCredential)
    #expect(PasskeyCredentialError.privateKeyNotFound.diagnosticCode == .passkeyIdentityUnavailable)
    #expect(PasskeyCredentialError.keychainUnexpectedStatus(-25_293).diagnosticCode == .passkeyKeychainFailure)
    #expect(PasskeyCredentialError.keychainUnexpectedStatus(-25_293).diagnosticMetadata.renderedFields == "status=-25293")
    #expect(PasskeyCredentialError.invalidClientDataHashLength.diagnosticMetadata.renderedFields == "reason=invalidInput")
    #expect(PasskeyCredentialError.invalidClientDataHashLength.diagnosticReason == .invalidInput)
}
