import Foundation

struct AppAutoFillCredentialSaveRequest: Sendable, Equatable, Codable {
    let serviceIdentifier: String
    let username: String
    let password: String
    let title: String

    init(
        serviceIdentifier: String,
        username: String,
        password: String,
        title: String = ""
    ) {
        self.serviceIdentifier = serviceIdentifier
        self.username = username
        self.password = password
        self.title = title
    }
}

struct AppAutoFillCredentialSaveInboxStore: Sendable {
    private struct Manifest: Codable, Sendable, Equatable {
        let schemaVersion: Int
        let createdAt: TimeInterval
        let items: [Item]
    }

    private struct Item: Codable, Sendable, Equatable {
        let relativeContentPath: String
    }

    static let defaultAppGroupIdentifier = "group.monica-pass.monica"

    let manifestURL: URL

    private let inboxDirectoryURL: URL
    private let contentDirectoryName = "contents"
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(containerURL: URL) {
        inboxDirectoryURL = containerURL.appendingPathComponent("autofill-save-inbox-v1", isDirectory: true)
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

    func saveIncomingRequest(
        _ request: AppAutoFillCredentialSaveRequest,
        now: Date = Date()
    ) throws {
        try saveIncomingRequests([request], now: now)
    }

    func saveIncomingRequests(
        _ requests: [AppAutoFillCredentialSaveRequest],
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

        let items = try requests.enumerated().map { index, request in
            let fileName = "save-\(index).json"
            let contentURL = contentDirectoryURL.appendingPathComponent(fileName)
            try encoder.encode(request).write(
                to: contentURL,
                options: [.atomic, .completeFileProtection]
            )
            return Item(relativeContentPath: "\(contentDirectoryName)/\(fileName)")
        }
        let manifest = Manifest(
            schemaVersion: 1,
            createdAt: now.timeIntervalSince1970,
            items: items
        )
        try encoder.encode(manifest).write(
            to: manifestURL,
            options: [.atomic, .completeFileProtection]
        )
    }

    func loadPendingSaveRequests() throws -> [AppAutoFillCredentialSaveRequest] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return []
        }
        let manifest = try decoder.decode(
            Manifest.self,
            from: try Data(contentsOf: manifestURL)
        )
        return try manifest.items.map { item in
            let contentURL = inboxDirectoryURL.appendingPathComponent(item.relativeContentPath)
            return try decoder.decode(
                AppAutoFillCredentialSaveRequest.self,
                from: try Data(contentsOf: contentURL)
            )
        }
    }

    func clearPendingSaveRequests() throws {
        try? FileManager.default.removeItem(at: inboxDirectoryURL)
    }
}
