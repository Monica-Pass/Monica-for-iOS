import Foundation

enum AppShareImportRequest: Sendable, Equatable {
    case url(URL)
    case text(String)
    case file(url: URL, mediaType: String)
}

struct AppShareExtensionInboxStore: Sendable {
    struct Manifest: Codable, Sendable, Equatable {
        let schemaVersion: Int
        let createdAt: TimeInterval
        let items: [Item]
    }

    struct Item: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable {
            case url
            case text
            case file
        }

        let kind: Kind
        let mediaType: String
        let fileName: String
        let relativeContentPath: String
    }

    static let defaultAppGroupIdentifier = "group.monica-pass.monica"

    let manifestURL: URL

    private let inboxDirectoryURL: URL
    private let contentDirectoryName = "contents"
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(containerURL: URL) {
        inboxDirectoryURL = containerURL.appendingPathComponent("share-inbox-v1", isDirectory: true)
        manifestURL = inboxDirectoryURL.appendingPathComponent("manifest.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    init?(appGroupIdentifier: String = Self.defaultAppGroupIdentifier) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        self.init(containerURL: containerURL)
    }

    func saveIncomingItems(
        _ requests: [AppShareImportRequest],
        now: Date = Date()
    ) throws {
        try FileManager.default.createDirectory(
            at: inboxDirectoryURL,
            withIntermediateDirectories: true
        )
        let contentDirectoryURL = inboxDirectoryURL.appendingPathComponent(contentDirectoryName, isDirectory: true)
        try? FileManager.default.removeItem(at: contentDirectoryURL)
        try FileManager.default.createDirectory(
            at: contentDirectoryURL,
            withIntermediateDirectories: true
        )

        var items: [Item] = []
        for (index, request) in requests.enumerated() {
            switch request {
            case .url(let url):
                let fileName = "url-\(index).txt"
                let contentURL = contentDirectoryURL.appendingPathComponent(fileName)
                try Data(url.absoluteString.utf8).write(
                    to: contentURL,
                    options: [.atomic, .completeFileProtection]
                )
                items.append(
                    Item(
                        kind: .url,
                        mediaType: "text/uri-list",
                        fileName: "",
                        relativeContentPath: "\(contentDirectoryName)/\(fileName)"
                    )
                )
            case .text(let text):
                let fileName = "text-\(index).txt"
                let contentURL = contentDirectoryURL.appendingPathComponent(fileName)
                try Data(text.utf8).write(
                    to: contentURL,
                    options: [.atomic, .completeFileProtection]
                )
                items.append(
                    Item(
                        kind: .text,
                        mediaType: "text/plain",
                        fileName: "",
                        relativeContentPath: "\(contentDirectoryName)/\(fileName)"
                    )
                )
            case .file(let url, let mediaType):
                let sanitizedFileName = Self.sanitizedFileName(url.lastPathComponent)
                let contentURL = contentDirectoryURL.appendingPathComponent("\(index)-\(sanitizedFileName)")
                try? FileManager.default.removeItem(at: contentURL)
                try FileManager.default.copyItem(at: url, to: contentURL)
                items.append(
                    Item(
                        kind: .file,
                        mediaType: mediaType,
                        fileName: sanitizedFileName,
                        relativeContentPath: "\(contentDirectoryName)/\(contentURL.lastPathComponent)"
                    )
                )
            }
        }

        let manifest = Manifest(
            schemaVersion: 1,
            createdAt: now.timeIntervalSince1970,
            items: items
        )
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: [.atomic, .completeFileProtection])
    }

    func loadPendingImportRequests() throws -> [AppShareImportRequest] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return []
        }
        let manifest = try decoder.decode(
            Manifest.self,
            from: try Data(contentsOf: manifestURL)
        )
        return try manifest.items.compactMap { item in
            let contentURL = inboxDirectoryURL.appendingPathComponent(item.relativeContentPath)
            switch item.kind {
            case .url:
                let value = try String(contentsOf: contentURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: value) else {
                    return nil
                }
                return .url(url)
            case .text:
                return .text(try String(contentsOf: contentURL, encoding: .utf8))
            case .file:
                let fileName = item.fileName.isEmpty
                    ? Self.sanitizedFileName(contentURL.lastPathComponent)
                    : item.fileName
                let displayURL = contentURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(fileName)
                if displayURL != contentURL {
                    try? FileManager.default.removeItem(at: displayURL)
                    try FileManager.default.copyItem(at: contentURL, to: displayURL)
                }
                return .file(url: displayURL, mediaType: item.mediaType)
            }
        }
    }

    func clearPendingImportRequests() throws {
        try? FileManager.default.removeItem(at: inboxDirectoryURL)
    }

    static func sanitizedFileName(_ value: String) -> String {
        let fallback = "shared-file"
        let lastComponent = value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? fallback
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: ".-_ "))
        let sanitizedScalars = lastComponent.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(sanitizedScalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? fallback : sanitized
    }
}
