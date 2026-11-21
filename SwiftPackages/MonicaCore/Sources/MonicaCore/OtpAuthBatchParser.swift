import Foundation

/// 批量 otpauth 导入中的一条有效链接。
public struct OtpAuthBatchEntry: Sendable, Equatable, Identifiable {
    public let lineNumber: Int
    public let draft: TotpImportDraft

    public var id: Int { lineNumber }

    public init(lineNumber: Int, draft: TotpImportDraft) {
        self.lineNumber = lineNumber
        self.draft = draft
    }
}

/// 批量 otpauth 导入中一条无法解析的链接。错误按行返回，绝不静默丢弃。
public struct OtpAuthBatchFailure: Sendable, Equatable, Identifiable {
    public let lineNumber: Int
    public let error: TotpError

    public var id: Int { lineNumber }

    public init(lineNumber: Int, error: TotpError) {
        self.lineNumber = lineNumber
        self.error = error
    }
}

public struct OtpAuthBatchResult: Sendable, Equatable {
    public let entries: [OtpAuthBatchEntry]
    public let failures: [OtpAuthBatchFailure]

    public init(entries: [OtpAuthBatchEntry], failures: [OtpAuthBatchFailure]) {
        self.entries = entries
        self.failures = failures
    }
}

/// 逐行解析 otpauth 链接。空行会被忽略，但任何非空坏行都会进入 `failures`。
public enum OtpAuthBatchParser {
    public static let maximumLineByteCount = TotpURIParser.maximumURILength

    public static func parse(_ text: String) -> OtpAuthBatchResult {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        var entries: [OtpAuthBatchEntry] = []
        var failures: [OtpAuthBatchFailure] = []

        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let lineNumber = index + 1
            guard line.utf8.count <= maximumLineByteCount else {
                failures.append(OtpAuthBatchFailure(lineNumber: lineNumber, error: .uriTooLong))
                continue
            }
            do {
                let draft = try TotpURIParser.parse(line)
                entries.append(OtpAuthBatchEntry(lineNumber: lineNumber, draft: draft))
            } catch let error as TotpError {
                failures.append(OtpAuthBatchFailure(lineNumber: lineNumber, error: error))
            } catch {
                failures.append(OtpAuthBatchFailure(lineNumber: lineNumber, error: .invalidURI))
            }
        }

        return OtpAuthBatchResult(entries: entries, failures: failures)
    }
}
