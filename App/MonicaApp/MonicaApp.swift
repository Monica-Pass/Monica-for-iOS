import CryptoKit
import Foundation
import MonicaSync
import SwiftUI

@main
struct MonicaApp: App {
    private let environment: MonicaAppEnvironment

    init() {
        let environment = MonicaAppEnvironment()
        self.environment = environment
        AppOneDriveGraphAcceptanceHarness.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(environment: environment)
        }
    }
}

enum AppOneDriveGraphAcceptanceHarness {
    static let launchArgument = "--monica-onedrive-graph-acceptance"

    static func shouldRun(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(launchArgument)
    }

    static func runIfRequested() {
        guard shouldRun() else {
            return
        }
        Task.detached {
            let exitCode = await run()
            fflush(stdout)
            fflush(stderr)
            Darwin.exit(exitCode)
        }
    }

    private static func run() async -> Int32 {
        var recorder = AcceptanceRecorder()
        log("START")
        recorder.append("START")
        do {
            let authenticationService = DefaultAppOneDriveMSALAuthenticationService()
            guard try await authenticationService.restoreSession() != nil else {
                throw AcceptanceError.missingPersistedSession
            }
            log("MSAL restored")
            recorder.append("MSAL restored")

            let provider = OneDriveCloudFileProvider(tokenProvider: authenticationService)
            let initialItems = try await provider.listFiles()
            log("Graph list ok: \(initialItems.count) file(s)")
            recorder.append("Graph list ok: \(initialItems.count) file(s)")

            let fileName = "monica-graph-acceptance.txt"
            let originalData = Data("Monica OneDrive Graph acceptance original".utf8)
            let updatedData = Data("Monica OneDrive Graph acceptance updated".utf8)

            let uploadReceipt = try await provider.uploadFile(named: fileName, data: originalData)
            guard uploadReceipt.name == fileName,
                  uploadReceipt.byteCount == originalData.count,
                  !uploadReceipt.itemID.isEmpty
            else {
                throw AcceptanceError.unexpectedUploadReceipt
            }
            log("Graph upload ok: \(uploadReceipt.name) \(uploadReceipt.byteCount) bytes")
            recorder.append("Graph upload ok: \(uploadReceipt.name) \(uploadReceipt.byteCount) bytes")

            let itemsAfterUpload = try await provider.listFiles()
            guard itemsAfterUpload.contains(where: { $0.id == uploadReceipt.itemID && $0.name == fileName }) else {
                throw AcceptanceError.uploadedItemMissingFromList
            }
            log("Graph post-upload list ok")
            recorder.append("Graph post-upload list ok")

            let downloadedOriginal = try await provider.downloadFile(id: uploadReceipt.itemID)
            guard downloadedOriginal.data == originalData,
                  downloadedOriginal.item.name == fileName,
                  downloadedOriginal.sha256 == sha256Hex(originalData)
            else {
                throw AcceptanceError.downloadedOriginalMismatch
            }
            log("Graph download original ok: \(downloadedOriginal.data.count) bytes")
            recorder.append("Graph download original ok: \(downloadedOriginal.data.count) bytes")

            guard let revision = uploadReceipt.revision, !revision.isEmpty else {
                throw AcceptanceError.missingRevision
            }
            let overwriteReceipt = try await provider.overwriteFile(
                id: uploadReceipt.itemID,
                data: updatedData,
                fileName: fileName,
                expectedRevision: revision
            )
            guard overwriteReceipt.name == fileName,
                  overwriteReceipt.byteCount == updatedData.count
            else {
                throw AcceptanceError.unexpectedOverwriteReceipt
            }
            log("Graph If-Match overwrite ok: \(overwriteReceipt.byteCount) bytes")
            recorder.append("Graph If-Match overwrite ok: \(overwriteReceipt.byteCount) bytes")

            let downloadedUpdated = try await provider.downloadFile(id: uploadReceipt.itemID)
            guard downloadedUpdated.data == updatedData,
                  downloadedUpdated.sha256 == sha256Hex(updatedData)
            else {
                throw AcceptanceError.downloadedUpdatedMismatch
            }
            log("Graph download updated ok: \(downloadedUpdated.data.count) bytes")
            recorder.append("Graph download updated ok: \(downloadedUpdated.data.count) bytes")
            log("PASS")
            recorder.append("PASS")
            recorder.write(status: "pass")
            return 0
        } catch {
            let errorDescription = redactedErrorDescription(error)
            log("FAIL \(errorDescription)")
            recorder.append("FAIL \(errorDescription)")
            recorder.write(status: "fail", error: errorDescription)
            return 1
        }
    }

    private static func log(_ message: String) {
        fputs("[MonicaOneDriveGraphAcceptance] \(message)\n", stderr)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func redactedErrorDescription(_ error: Error) -> String {
        var message = String(describing: error)
        let sensitiveKeys = [
            "access_token",
            "refresh_token",
            "id_token",
            "client_secret",
            "password",
            "code",
            "state"
        ]
        for key in sensitiveKeys {
            message = message.replacingOccurrences(
                of: #"(?i)(\b\#(NSRegularExpression.escapedPattern(for: key))=)[^&\s]+"#,
                with: "$1<redacted>",
                options: .regularExpression
            )
        }
        return message
    }

    private enum AcceptanceError: Error {
        case missingPersistedSession
        case unexpectedUploadReceipt
        case uploadedItemMissingFromList
        case downloadedOriginalMismatch
        case missingRevision
        case unexpectedOverwriteReceipt
        case downloadedUpdatedMismatch
    }

    private struct AcceptanceRecorder {
        private let startedAt = Date()
        private var events: [String] = []

        mutating func append(_ event: String) {
            events.append(event)
            write(status: "running")
        }

        func write(status: String, error: String? = nil) {
            let payload: [String: Any] = [
                "status": status,
                "startedAt": ISO8601DateFormatter().string(from: startedAt),
                "updatedAt": ISO8601DateFormatter().string(from: Date()),
                "events": events,
                "error": error ?? NSNull()
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: Self.outputURL(), options: [.atomic])
            } catch {
                log("result write failed: \(redactedErrorDescription(error))")
            }
        }

        private static func outputURL() throws -> URL {
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return documents.appendingPathComponent("onedrive-graph-acceptance.json")
        }
    }
}
