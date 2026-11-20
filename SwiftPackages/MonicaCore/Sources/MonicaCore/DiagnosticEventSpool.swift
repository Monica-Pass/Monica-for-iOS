import Foundation

/// A small, app-group JSON Lines spool that lets the AutoFill extension record
/// structured diagnostic events for the containing app to pick up later.
///
/// The extension is a separate process with its own container, so it cannot
/// write into the app's in-memory `DiagnosticLog`. It writes to a file both
/// processes can reach through the shared app group instead; the app drains the
/// file when the developer section opens. The file is byte-capped and the app
/// re-validates every field it reads, so neither a truncated write nor a
/// tampered file can inject free-form text into the log.
public struct DiagnosticEventSpool: Sendable {
    public enum SpoolError: Error, Equatable, Sendable {
        case writeFailed(Int32)
        case readFailed(Int32)
    }

    public let fileURL: URL
    public let maximumEvents: Int
    public let maximumBytes: Int

    public init(fileURL: URL, maximumEvents: Int = 200, maximumBytes: Int = 128 * 1024) {
        self.fileURL = fileURL
        self.maximumEvents = max(1, maximumEvents)
        self.maximumBytes = max(1024, maximumBytes)
    }

    /// `Library/Caches/Diagnostics/extension-diagnostics.jsonl` inside the app
    /// group. Returns `nil` when the group container is unavailable, which is
    /// the normal case on a locked device before first unlock.
    public static func defaultFileURL(appGroupIdentifier: String) -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        return container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("extension-diagnostics.jsonl", isDirectory: false)
    }

    /// Appends one event as a single JSON line. Failures are reported, never
    /// thrown as a crash: a diagnostics write must not break passkey flows.
    @discardableResult
    public func append(_ event: DiagnosticEvent) -> Bool {
        guard let line = Self.encode(event) else {
            return false
        }
        do {
            try withExclusiveLock { descriptor in
                guard try Self.sizeOfFile(descriptor) < off_t(maximumBytes) else {
                    return
                }
                try Self.writeAll(Data(line.utf8), to: descriptor)
            }
            return true
        } catch {
            return false
        }
    }

    public func append(contentsOf events: [DiagnosticEvent]) {
        for event in events {
            append(event)
        }
    }

    /// Reads every complete line, then truncates the file. Called by the app on
    /// the main thread when the developer section opens.
    public func drain() -> [DiagnosticEvent] {
        let data: Data
        do {
            data = try withExclusiveLock { descriptor in
                let bytes = try Self.readAll(descriptor)
                try Self.truncate(descriptor)
                return bytes
            }
        } catch {
            return []
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { Self.decode(String($0)) }
    }

    /// Keeps only the newest lines, bounded by both count and bytes. Called
    /// after a drain so a spool the app could not read does not grow without
    /// bound.
    public func trimToCapacity() {
        guard let data = try? Data(contentsOf: fileURL) else {
            return
        }
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            return
        }

        var kept: [Data] = []
        var keptBytes = 0
        for line in lines.reversed() {
            guard kept.count < maximumEvents else { break }
            let lineBytes = line.count + 1
            if keptBytes + lineBytes > maximumBytes, !kept.isEmpty {
                break
            }
            kept.append(Data(line) + Data([UInt8(ascii: "\n")]))
            keptBytes += lineBytes
        }
        guard kept.count < lines.count else {
            return
        }

        let replacement = kept.reversed().reduce(into: Data()) { $0.append($1) }
        try? withExclusiveLock { descriptor in
            try Self.truncate(descriptor)
            try Self.writeAll(replacement, to: descriptor)
        }
    }

    // MARK: - Coding

    static func encode(_ event: DiagnosticEvent) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(event),
              let line = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        // A JSON object cannot contain a raw newline; this guard keeps the
        // one-event-per-line invariant explicit anyway.
        guard !line.contains("\n"), !line.contains("\r") else {
            return nil
        }
        return line + "\n"
    }

    static func decode(_ line: String) -> DiagnosticEvent? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = line.data(using: .utf8),
              let event = try? decoder.decode(DiagnosticEvent.self, from: data)
        else {
            return nil
        }
        return event.sanitizedForIngestion()
    }

    // MARK: - POSIX file handling

    private func withExclusiveLock<T>(_ body: (Int32) throws -> T) throws -> T {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(fileURL.path, O_RDWR | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else {
            throw SpoolError.writeFailed(errno)
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw SpoolError.writeFailed(errno)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body(descriptor)
    }

    private static func sizeOfFile(_ descriptor: Int32) throws -> off_t {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw SpoolError.readFailed(errno)
        }
        return status.st_size
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base.advanced(by: offset), buffer.count - offset)
                guard written > 0 else {
                    throw SpoolError.writeFailed(errno)
                }
                offset += written
            }
        }
    }

    private static func readAll(_ descriptor: Int32) throws -> Data {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw SpoolError.readFailed(errno)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, raw.count)
            }
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    private static func truncate(_ descriptor: Int32) throws {
        guard ftruncate(descriptor, 0) == 0 else {
            throw SpoolError.writeFailed(errno)
        }
    }
}

extension DiagnosticEvent {
    /// Re-validates every field that came out of the spool. The enum cases and
    /// numeric ranges are enforced by `Codable` alone, but the host and file
    /// name carry text, so they are validated again at the trust boundary.
    func sanitizedForIngestion() -> DiagnosticEvent {
        DiagnosticEvent(
            id: id,
            timestamp: timestamp,
            level: level,
            module: module,
            code: code,
            metadata: metadata.sanitizedForIngestion()
        )
    }
}
