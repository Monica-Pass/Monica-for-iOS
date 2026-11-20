import Foundation
import MonicaCore
import MonicaMDBX
import MonicaStorage
import Observation

/// Owns the redacted diagnostic ring buffer on the app side (issue #65).
///
/// The buffer itself lives in `MonicaCore` so it can be unit-tested without a
/// simulator; this type only adds the persisted developer-mode flag, the level
/// filter the developer section edits, and the bridge that folds in events the
/// AutoFill extension recorded into the shared app-group spool.
@MainActor
@Observable
final class AppDiagnosticsCenter {
    enum DefaultsKey {
        static let developerModeUnlocked = "Monica.Diagnostics.DeveloperModeUnlocked"
        static let recordingLevel = "Monica.Diagnostics.RecordingLevel"
        static let displayLevel = "Monica.Diagnostics.DisplayLevel"
        static let includesHostNames = "Monica.Diagnostics.IncludesHostNames"
    }

    static let shared = AppDiagnosticsCenter()
    static let exportBaseFileName = "monica-diagnostics"

    let log: DiagnosticLog
    private let defaults: UserDefaults

    private(set) var isDeveloperModeUnlocked: Bool
    /// Levels the developer section lists. Persisted, but a display-only filter:
    /// the recording threshold is `recordingLevel`.
    var displayLevel: DiagnosticLevel {
        didSet {
            defaults.set(displayLevel.rawValue, forKey: DefaultsKey.displayLevel)
        }
    }
    /// The threshold the ring buffer records at. `.info` (release default) keeps
    /// detailed events out of the buffer entirely.
    var recordingLevel: DiagnosticLevel {
        didSet {
            log.setMinimumLevel(recordingLevel)
            defaults.set(recordingLevel.rawValue, forKey: DefaultsKey.recordingLevel)
            log.record(
                .diagnosticsLevelChanged,
                level: .info,
                module: .diagnostics,
                metadata: .reason(recordingLevel.diagnosticTag)
            )
        }
    }
    var includesHostNames: Bool {
        didSet {
            log.setIncludesHostNames(includesHostNames)
            defaults.set(includesHostNames, forKey: DefaultsKey.includesHostNames)
        }
    }

    private(set) var events: [DiagnosticEvent] = []
    private(set) var lastImportedExtensionEventCount = 0
    private(set) var browseBlockedByLockedVault = false
    private(set) var unlockTracker = DeveloperModeUnlockTracker()

    var isDetailedLoggingEnabled: Bool {
        get { recordingLevel == .debug }
        set { recordingLevel = newValue ? .debug : .info }
    }

    init(defaults: UserDefaults = .standard, log: DiagnosticLog = .shared) {
        self.defaults = defaults
        self.log = log

        self.isDeveloperModeUnlocked = defaults.bool(forKey: DefaultsKey.developerModeUnlocked)
        let storedRecording = defaults.string(forKey: DefaultsKey.recordingLevel)
            .flatMap(DiagnosticLevel.init(rawValue:))
        // Release default: only `.info` and above are recorded. A stored value is
        // honoured, but never silently below the release floor at first launch.
        self.recordingLevel = storedRecording ?? .info
        let storedDisplay = defaults.string(forKey: DefaultsKey.displayLevel)
            .flatMap(DiagnosticLevel.init(rawValue:))
        self.displayLevel = storedDisplay ?? (storedRecording ?? .info)
        self.includesHostNames = defaults.object(forKey: DefaultsKey.includesHostNames) as? Bool ?? true

        log.setMinimumLevel(recordingLevel)
        log.setIncludesHostNames(includesHostNames)
    }

    // MARK: - Developer mode

    /// Counts one tap on the version row. Returns `true` on the tap that unlock
    /// the section, matching the Android "tap the version 7 times" affordance.
    @discardableResult
    func registerDeveloperModeTap(at timestamp: Date = Date()) -> Bool {
        let unlocked = unlockTracker.registerTap(at: timestamp)
        if unlocked {
            revealDeveloperMode()
        }
        return unlocked
    }

    func revealDeveloperMode() {
        unlockTracker.reset()
        guard !isDeveloperModeUnlocked else { return }
        isDeveloperModeUnlocked = true
        defaults.set(true, forKey: DefaultsKey.developerModeUnlocked)
        log.record(.diagnosticsDeveloperModeUnlocked, level: .info, module: .diagnostics)
    }

    func hideDeveloperMode() {
        unlockTracker.reset()
        guard isDeveloperModeUnlocked else { return }
        isDeveloperModeUnlocked = false
        defaults.set(false, forKey: DefaultsKey.developerModeUnlocked)
        events = []
        log.record(.diagnosticsDeveloperModeHidden, level: .info, module: .diagnostics)
    }

    // MARK: - Browsing

    /// Reloads what the developer section shows. A locked vault never sees the
    /// buffer: the rejection lives in `MonicaCore` so the UI cannot bypass it.
    func reloadEvents(vaultIsUnlocked: Bool) {
        do {
            events = try log.events(minimumLevel: displayLevel, vaultIsUnlocked: vaultIsUnlocked)
            browseBlockedByLockedVault = false
        } catch {
            // Locked browsing is rejected in the core buffer; the UI only mirrors
            // the state, so reloads do not spam the log with their own refusals.
            events = []
            browseBlockedByLockedVault = true
        }
    }

    func clear() {
        log.clear()
        events = []
        log.record(.diagnosticsCleared, level: .info, module: .diagnostics)
    }

    // MARK: - Export

    func exportReport(vaultIsUnlocked: Bool, generatedAt: Date = Date()) throws -> String {
        do {
            let report = try log.exportReport(
                minimumLevel: displayLevel,
                vaultIsUnlocked: vaultIsUnlocked,
                generatedAt: generatedAt
            )
            log.record(
                .diagnosticsExported,
                level: .info,
                module: .diagnostics,
                metadata: .count(events.count)
            )
            return report
        } catch {
            log.record(.diagnosticsExportBlockedLocked, level: .warning, module: .diagnostics, metadata: .reason(.locked))
            throw error
        }
    }

    func exportFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(Self.exportBaseFileName)-\(formatter.string(from: now)).txt"
    }

    // MARK: - Extension spool

    /// Drains events the AutoFill extension wrote into the shared app group and
    /// folds them into the app buffer. Every event is re-validated on ingest.
    @discardableResult
    func importExtensionEvents(appGroupIdentifier: String) -> Int {
        guard let spoolFileURL = DiagnosticEventSpool.defaultFileURL(appGroupIdentifier: appGroupIdentifier) else {
            return 0
        }
        let spool = DiagnosticEventSpool(fileURL: spoolFileURL)
        let drained = spool.drain()
        guard !drained.isEmpty else { return 0 }
        log.ingest(drained)
        lastImportedExtensionEventCount = drained.count
        log.record(
            .diagnosticsExtensionEventsImported,
            level: .info,
            module: .diagnostics,
            metadata: .count(drained.count)
        )
        return drained.count
    }
}

extension DiagnosticLevel {
    /// Closed tag used when a level change is itself recorded.
    var diagnosticTag: DiagnosticTag {
        switch self {
        case .debug: return .debugLevel
        case .info: return .infoLevel
        case .warning: return .warningLevel
        case .error: return .errorLevel
        }
    }
}

// MARK: - App-side emission helpers

/// Small adapters so app call sites stay one line and can only ever emit a code
/// plus closed metadata (issue #65). Raw `Error` values never reach the buffer.
enum AppDiagnosticEmission {
    /// Passkey create / registration / inbox-import failures.
    static func passkeyFailure(_ error: Error, stage: DiagnosticTag) {
        var metadata = DiagnosticMetadata.stage(stage)
        let code: DiagnosticCode
        if let coded = error as? any DiagnosticCodedError {
            code = coded.diagnosticCode
            metadata = metadata.merging(coded.diagnosticMetadata, .reason(coded.diagnosticReason))
        } else if error is LocalVaultRepositoryError {
            code = stage == .importInbox ? .passkeyInboxImportFailed : .passkeyRegistrationFailed
            metadata = metadata.merging(.reason(.storage))
        } else {
            code = stage == .importInbox ? .passkeyInboxImportFailed : .passkeyRegistrationFailed
            metadata = metadata.merging(.reason(.commandFailed))
        }
        DiagnosticLog.shared.record(code, level: .error, module: .passkey, metadata: metadata)
    }

    /// Vault create / open failures, including the MDBX surface.
    static func vaultFailure(_ error: Error, stage: DiagnosticTag) {
        var metadata = DiagnosticMetadata.stage(stage)
        var reason: DiagnosticTag = .storage
        var code: DiagnosticCode = stage == .create ? .vaultCreateFailed : .vaultOpenFailed

        if let mdbx = error as? MonicaMDBXError {
            switch mdbx {
            case .unavailableOnCurrentPlatform:
                code = .vaultMDBXUnavailable
                reason = .mdbxUnavailable
            case .verificationFailed:
                code = .vaultMDBXVerificationFailed
                reason = .verificationFailed
            }
        } else if error is LocalVaultRepositoryError {
            reason = .storage
        } else if let coded = error as? any DiagnosticCodedError {
            code = coded.diagnosticCode
            metadata = metadata.merging(coded.diagnosticMetadata)
            reason = coded.diagnosticReason
        }
        DiagnosticLog.shared.record(code, level: .error, module: .vault, metadata: metadata.merging(.reason(reason)))
    }
}
