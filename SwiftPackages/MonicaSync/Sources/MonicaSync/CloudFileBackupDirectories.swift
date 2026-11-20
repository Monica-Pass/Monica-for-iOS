import Foundation

/// A directory inside a provider's application folder that can hold vault backups.
public struct CloudFileBackupDirectory: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let parentID: String?
    public let path: String

    public init(id: String, name: String, parentID: String? = nil, path: String = "") {
        self.id = id
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmedName.isEmpty ? "未命名目录" : trimmedName
        self.parentID = parentID
        self.path = Self.normalizedPath(path)
    }

    /// A path relative to the application folder, without provider-specific prefixes.
    public var displayPath: String {
        path.isEmpty ? name : path
    }

    public var redactedSummary: String {
        "备份目录 \(displayPath)"
    }

    static func normalizedPath(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }
}

/// Per-account backup destination and retention policy.
public struct CloudFileBackupPreferences: Sendable, Equatable, Codable {
    public var directory: CloudFileBackupDirectory?
    public var usesTimestampedFileNames: Bool
    public var retainedVersionCount: Int

    public init(
        directory: CloudFileBackupDirectory? = nil,
        usesTimestampedFileNames: Bool = false,
        retainedVersionCount: Int = 10
    ) {
        self.directory = directory
        self.usesTimestampedFileNames = usesTimestampedFileNames
        self.retainedVersionCount = Self.clampedRetainedVersionCount(retainedVersionCount)
    }

    public var directoryID: String? {
        directory?.id
    }

    public var displayPath: String {
        directory?.displayPath ?? "默认位置"
    }

    public var isUsingDefaultLocation: Bool {
        directory == nil
    }

    private enum CodingKeys: String, CodingKey {
        case directory
        case usesTimestampedFileNames
        case retainedVersionCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.directory = try container.decodeIfPresent(CloudFileBackupDirectory.self, forKey: .directory)
        self.usesTimestampedFileNames = try container.decodeIfPresent(Bool.self, forKey: .usesTimestampedFileNames) ?? false
        self.retainedVersionCount = Self.clampedRetainedVersionCount(
            try container.decodeIfPresent(Int.self, forKey: .retainedVersionCount) ?? 10
        )
    }

    private static func clampedRetainedVersionCount(_ value: Int) -> Int {
        min(max(value, 1), 50)
    }
}

public enum CloudFileUploadConflictBehavior: String, Sendable, Equatable, Codable {
    case fail
    case replace
}

public struct CloudFileBackupDirectoryListing: Sendable, Equatable {
    public let directory: CloudFileBackupDirectory?
    public let directories: [CloudFileBackupDirectory]
    public let files: [CloudFileItem]

    public init(
        directory: CloudFileBackupDirectory? = nil,
        directories: [CloudFileBackupDirectory] = [],
        files: [CloudFileItem] = []
    ) {
        self.directory = directory
        self.directories = directories
        self.files = files
    }
}

/// Directory-aware companion to `CloudFileProvider`.
///
/// Providers that support this protocol can browse and create directories inside
/// their application folder, and write files into a selected directory.
public protocol CloudFileBackupDirectoryProviding: Sendable {
    /// Lists `id`, or the application folder root when `id` is `nil`.
    func listBackupDirectory(id: String?) async throws -> CloudFileBackupDirectoryListing

    /// Creates a directory below `parentID`, or below the application folder root when `nil`.
    func createBackupDirectory(named name: String, parentID: String?) async throws -> CloudFileBackupDirectory

    /// Uploads `data` into a directory, honoring the conflict behavior.
    func uploadFile(
        named fileName: String,
        data: Data,
        inDirectory directoryID: String?,
        conflictBehavior: CloudFileUploadConflictBehavior
    ) async throws -> CloudFileWriteReceipt
}

public extension CloudFileBackupDirectoryProviding {
    func uploadFile(
        named fileName: String,
        data: Data,
        inDirectory directoryID: String?
    ) async throws -> CloudFileWriteReceipt {
        try await uploadFile(
            named: fileName,
            data: data,
            inDirectory: directoryID,
            conflictBehavior: .fail
        )
    }
}

/// Timestamped backup file names use a stable UTC stamp so retention is deterministic.
public enum CloudFileBackupFileNameFormatter {
    public static let timestampFormat = "yyyyMMdd-HHmmss"

    public static func timestampedFileName(baseName: String, date: Date) -> String {
        let parts = split(baseName: baseName)
        let stamp = formatter().string(from: date)
        if parts.extension.isEmpty {
            return "\(parts.stem)-\(stamp)"
        }
        return "\(parts.stem)-\(stamp).\(parts.extension)"
    }

    public static func timestamp(fromTimestampedFileName fileName: String, baseName: String) -> Date? {
        let parts = split(baseName: baseName)
        let prefix = "\(parts.stem)-"
        guard fileName.hasPrefix(prefix) else {
            return nil
        }
        var remainder = String(fileName.dropFirst(prefix.count))
        if !parts.extension.isEmpty {
            let suffix = ".\(parts.extension)"
            guard remainder.hasSuffix(suffix) else {
                return nil
            }
            remainder = String(remainder.dropLast(suffix.count))
        }
        guard remainder.count == timestampFormat.count else {
            return nil
        }
        return formatter().date(from: remainder)
    }

    public static func isTimestampedBackup(fileName: String, baseName: String) -> Bool {
        timestamp(fromTimestampedFileName: fileName, baseName: baseName) != nil
    }

    public static func split(baseName: String) -> (stem: String, extension: String) {
        let name = cleanedName(baseName)
        let nsName = name as NSString
        let pathExtension = nsName.pathExtension
        let stem = nsName.deletingPathExtension
        return (stem.isEmpty ? name : stem, pathExtension)
    }

    private static func cleanedName(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        let lastComponent = normalized.split(separator: "/").last.map(String.init) ?? ""
        let trimmed = lastComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "monica-backup.mdbx" : trimmed
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = timestampFormat
        return formatter
    }
}

/// Retention only ever considers files created by the timestamped naming policy.
public enum CloudFileBackupRetention {
    public static func filesToPrune(
        from files: [CloudFileItem],
        baseName: String,
        retainedVersions: Int
    ) -> [CloudFileItem] {
        let keep = max(1, retainedVersions)
        let candidates: [(item: CloudFileItem, date: Date)] = files.compactMap { item in
            guard let date = CloudFileBackupFileNameFormatter.timestamp(
                fromTimestampedFileName: item.name,
                baseName: baseName
            ) else {
                return nil
            }
            return (item, date)
        }
        .sorted { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date > rhs.date
            }
            return lhs.item.name > rhs.item.name
        }
        return candidates.dropFirst(keep).map(\.item)
    }

    public static func retainedFiles(
        from files: [CloudFileItem],
        baseName: String,
        retainedVersions: Int
    ) -> [CloudFileItem] {
        let prunedIDs = Set(
            filesToPrune(from: files, baseName: baseName, retainedVersions: retainedVersions)
                .map(\.id)
        )
        return files.filter { !prunedIDs.contains($0.id) }
    }
}

/// Validation shared by every provider that creates directories.
public enum CloudFileBackupDirectoryName {
    public static let maximumLength = 100

    public static func validated(_ value: String, provider: CloudFileProviderKind) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "\"*:<>?|/\\")
        let hasControlCharacter = trimmed.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              trimmed.count <= maximumLength,
              !trimmed.hasSuffix("."),
              !hasControlCharacter,
              trimmed.rangeOfCharacter(from: forbidden) == nil
        else {
            throw CloudFileProviderError.invalidDirectoryName(provider: provider)
        }
        return trimmed
    }
}
