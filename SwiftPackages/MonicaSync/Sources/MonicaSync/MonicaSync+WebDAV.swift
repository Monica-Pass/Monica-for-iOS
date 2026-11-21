// MARK: - WebDAV 备份客户端（端点 / 打包 / 校验 / 传输）

import Foundation

public struct WebDAVEndpoint: Sendable, Equatable {
    public let baseURL: URL
    public let username: String
    public let password: String

    public init(
        baseURL: URL,
        username: String,
        password: String
    ) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }

    func url(for fileName: String) -> URL {
        baseURL.appendingPathComponent(fileName)
    }

    var authorizationHeader: String {
        let credentials = "\(username):\(password)"
        return "Basic \(Data(credentials.utf8).base64EncodedString())"
    }
}

public struct WebDAVBackupPackage: Sendable, Equatable {
    public let fileName: String
    public let data: Data
    public let sha256: String

    public init(fileName: String, data: Data) {
        self.fileName = fileName
        self.data = data
        self.sha256 = data.monicaSHA256Hex
    }
}

public struct WebDAVBackupReceipt: Sendable, Equatable {
    public let remoteURL: URL
    public let byteCount: Int
    public let sha256: String

    public init(remoteURL: URL, byteCount: Int, sha256: String) {
        self.remoteURL = remoteURL
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct WebDAVDownloadedBackup: Sendable, Equatable {
    public let fileName: String
    public let remoteURL: URL
    public let data: Data
    public let sha256: String

    public init(fileName: String, remoteURL: URL, data: Data, sha256: String) {
        self.fileName = fileName
        self.remoteURL = remoteURL
        self.data = data
        self.sha256 = sha256
    }
}

public struct WebDAVBackupItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let fileName: String
    public let byteCount: Int
    public let modifiedAt: Date?

    public init(
        fileName: String,
        byteCount: Int,
        modifiedAt: Date? = nil
    ) {
        let sanitized = sanitizedCloudFileName(fileName)
        self.id = sanitized
        self.fileName = sanitized
        self.byteCount = max(0, byteCount)
        self.modifiedAt = modifiedAt
    }

    public var isPermanent: Bool {
        let base = fileName.replacingOccurrences(of: ".mdbx", with: "")
        return base.hasSuffix("_permanent")
    }

    public var redactedSummary: String {
        "\(fileName) \(byteCount) 字节"
    }
}

public struct WebDAVRestorePreview: Sendable, Equatable {
    public let fileName: String
    public let byteCount: Int
    public let sha256: String

    public init(_ backup: WebDAVDownloadedBackup) throws {
        self.fileName = backup.fileName
        self.byteCount = backup.data.count
        self.sha256 = backup.sha256
    }
}

public struct WebDAVTransportRequest: Sendable, Equatable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data?

    public init(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct WebDAVTransportResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol WebDAVTransport {
    func send(_ request: WebDAVTransportRequest) async throws -> WebDAVTransportResponse
}

public struct WebDAVClient {
    private let endpoint: WebDAVEndpoint
    private let transport: any WebDAVTransport

    public init(endpoint: WebDAVEndpoint, transport: (any WebDAVTransport)? = nil) {
        self.endpoint = endpoint
        self.transport = transport ?? URLSessionWebDAVTransport(identity: WebDAVTrustIdentity(endpoint: endpoint))
    }

    public func upload(_ package: WebDAVBackupPackage) async throws -> WebDAVBackupReceipt {
        let remoteURL = endpoint.url(for: package.fileName)
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "PUT",
                url: remoteURL,
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Content-Type": "application/octet-stream",
                    "X-Monica-Backup-SHA256": package.sha256
                ],
                body: package.data
            )
        )

        guard [200, 201, 204].contains(response.statusCode) else {
            throw WebDAVError.unexpectedStatus(operation: "upload", statusCode: response.statusCode)
        }

        let checksumResponse = try await transport.send(
            WebDAVTransportRequest(
                method: "PUT",
                url: endpoint.url(for: package.sidecarFileName),
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Content-Type": "text/plain; charset=utf-8"
                ],
                body: Data("\(package.sha256)\n".utf8)
            )
        )
        guard [200, 201, 204].contains(checksumResponse.statusCode) else {
            throw WebDAVError.unexpectedStatus(
                operation: "upload checksum",
                statusCode: checksumResponse.statusCode
            )
        }

        return WebDAVBackupReceipt(
            remoteURL: remoteURL,
            byteCount: package.data.count,
            sha256: package.sha256
        )
    }

    public func download(fileName: String) async throws -> WebDAVDownloadedBackup {
        let remoteURL = endpoint.url(for: fileName)
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "GET",
                url: remoteURL,
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Accept": "application/octet-stream"
                ]
            )
        )

        guard response.statusCode == 200 else {
            throw WebDAVError.unexpectedStatus(operation: "download", statusCode: response.statusCode)
        }

        let computedSHA256 = response.body.monicaSHA256Hex
        let expectedSHA256: String
        if let headerSHA256 = response.headerValue("X-Monica-Backup-SHA256") {
            expectedSHA256 = headerSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            expectedSHA256 = try await downloadSidecarChecksum(fileName: fileName)
        }

        if expectedSHA256.lowercased() != computedSHA256 {
            throw WebDAVError.integrityCheckFailed
        }

        return WebDAVDownloadedBackup(
            fileName: fileName,
            remoteURL: remoteURL,
            data: response.body,
            sha256: computedSHA256
        )
    }

    public func listBackups() async throws -> [WebDAVBackupItem] {
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "PROPFIND",
                url: endpoint.baseURL,
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Depth": "1",
                    "Accept": "application/xml,text/xml"
                ]
            )
        )
        guard response.statusCode == 207 || response.statusCode == 200 else {
            throw WebDAVError.unexpectedStatus(operation: "list", statusCode: response.statusCode)
        }
        return Self.parseBackupItems(from: response.body)
            .filter { !$0.fileName.hasSuffix(".sha256") }
            .filter { $0.fileName.lowercased().hasSuffix(".mdbx") }
            .sorted(by: { lhs, rhs in
                switch (lhs.modifiedAt, rhs.modifiedAt) {
                case let (lhsDate?, rhsDate?):
                    if lhsDate == rhsDate { return lhs.fileName < rhs.fileName }
                    return lhsDate > rhsDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.fileName < rhs.fileName
                }
            })
    }

    public func deleteBackup(fileName: String) async throws {
        try await deleteFile(fileName: sanitizedCloudFileName(fileName), operation: "delete")
        do {
            try await deleteFile(
                fileName: WebDAVBackupPackage.sidecarFileName(for: sanitizedCloudFileName(fileName)),
                operation: "delete checksum"
            )
        } catch WebDAVError.unexpectedStatus(let operation, let statusCode)
            where operation == "delete checksum" && statusCode == 404 {
            return
        }
    }

    public func setBackupPermanent(fileName: String, isPermanent: Bool) async throws -> WebDAVBackupItem {
        let currentName = sanitizedCloudFileName(fileName)
        let nextName = permanentFileName(for: currentName, isPermanent: isPermanent)
        guard currentName != nextName else {
            return WebDAVBackupItem(fileName: currentName, byteCount: 0)
        }
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "MOVE",
                url: endpoint.url(for: currentName),
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Destination": endpoint.url(for: nextName).absoluteString,
                    "Overwrite": "F"
                ]
            )
        )
        guard [200, 201, 204].contains(response.statusCode) else {
            throw WebDAVError.unexpectedStatus(operation: "mark permanent", statusCode: response.statusCode)
        }
        return WebDAVBackupItem(fileName: nextName, byteCount: 0)
    }

    public func cleanupBackups(
        _ backups: [WebDAVBackupItem],
        olderThan cutoff: Date
    ) async throws -> [WebDAVBackupItem] {
        var deleted: [WebDAVBackupItem] = []
        for backup in backups where !backup.isPermanent {
            guard let modifiedAt = backup.modifiedAt, modifiedAt < cutoff else {
                continue
            }
            try await deleteBackup(fileName: backup.fileName)
            deleted.append(backup)
        }
        return deleted
    }

    private func downloadSidecarChecksum(fileName: String) async throws -> String {
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "GET",
                url: endpoint.url(for: WebDAVBackupPackage.sidecarFileName(for: fileName)),
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Accept": "text/plain"
                ]
            )
        )

        guard response.statusCode == 200 else {
            throw WebDAVError.unexpectedStatus(
                operation: "download checksum",
                statusCode: response.statusCode
            )
        }

        guard let checksum = String(data: response.body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !checksum.isEmpty
        else {
            throw WebDAVError.integrityCheckFailed
        }

        return checksum
    }

    private func deleteFile(fileName: String, operation: String) async throws {
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "DELETE",
                url: endpoint.url(for: fileName),
                headers: ["Authorization": endpoint.authorizationHeader]
            )
        )
        guard [200, 202, 204].contains(response.statusCode) else {
            throw WebDAVError.unexpectedStatus(operation: operation, statusCode: response.statusCode)
        }
    }

    private func permanentFileName(for fileName: String, isPermanent: Bool) -> String {
        let suffix = "_permanent"
        let extensionText = ".mdbx"
        guard fileName.lowercased().hasSuffix(extensionText) else {
            return isPermanent && !fileName.hasSuffix(suffix) ? fileName + suffix : fileName.replacingOccurrences(of: suffix, with: "")
        }
        let base = String(fileName.dropLast(extensionText.count))
        if isPermanent {
            return base.hasSuffix(suffix) ? fileName : "\(base)\(suffix)\(extensionText)"
        }
        return "\(base.replacingOccurrences(of: suffix, with: ""))\(extensionText)"
    }

    private static func parseBackupItems(from data: Data) -> [WebDAVBackupItem] {
        guard let xml = String(data: data, encoding: .utf8) else {
            return []
        }
        return xml
            .components(separatedBy: "</")
            .joined(separator: "</")
            .matches(pattern: #"<[^:>]*:?response\b[\s\S]*?</[^:>]*:?response>"#)
            .compactMap { response in
                guard let href = response.firstMatch(pattern: #"<[^:>]*:?href[^>]*>([\s\S]*?)</[^:>]*:?href>"#),
                      !response.contains("<d:collection") && !response.contains("<collection")
                else {
                    return nil
                }
                let fileName = href
                    .removingPercentEncoding?
                    .split(separator: "/")
                    .last
                    .map(String.init) ?? href
                let byteCount = response.firstMatch(pattern: #"<[^:>]*:?getcontentlength[^>]*>([\s\S]*?)</[^:>]*:?getcontentlength>"#)
                    .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
                let modifiedAt = response.firstMatch(pattern: #"<[^:>]*:?getlastmodified[^>]*>([\s\S]*?)</[^:>]*:?getlastmodified>"#)
                    .flatMap(Self.httpDate)
                return WebDAVBackupItem(fileName: fileName, byteCount: byteCount, modifiedAt: modifiedAt)
            }
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private extension WebDAVBackupPackage {
    var sidecarFileName: String {
        Self.sidecarFileName(for: fileName)
    }

    static func sidecarFileName(for fileName: String) -> String {
        "\(fileName).sha256"
    }
}

/// URLSession based WebDAV transport with Trust On First Use support for the
/// server certificate.
///
/// The transport never disables TLS validation globally: every request runs on an
/// ephemeral session whose delegate only answers `NSURLAuthenticationMethodServerTrust`.
/// A chain that the system trusts is handed back to URLSession untouched; a chain
/// the system rejects is accepted only when its SHA-256 fingerprint matches the pin
/// the user confirmed for this `host:port + user` scope.
public final class URLSessionWebDAVTransport: WebDAVTransport, @unchecked Sendable {
    public let identity: WebDAVTrustIdentity

    private let trustStore: any WebDAVCertificateTrustStore
    private let configuration: URLSessionConfiguration
    private let clock: @Sendable () -> Date

    public init(
        identity: WebDAVTrustIdentity,
        trustStore: any WebDAVCertificateTrustStore = KeychainWebDAVCertificateTrustStore(),
        configuration: URLSessionConfiguration = .ephemeral,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.identity = identity
        self.trustStore = trustStore
        self.configuration = configuration
        self.clock = now
    }

    public func send(_ request: WebDAVTransportRequest) async throws -> WebDAVTransportResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        request.headers.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let recorder = WebDAVServerTrustOutcomeRecorder()
        let delegate = WebDAVServerTrustDelegate(
            username: identity.username,
            trustStore: trustStore,
            recorder: recorder,
            now: clock
        )
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer {
            session.finishTasksAndInvalidate()
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw Self.translatedError(error, recorder: recorder)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.nonHTTPResponse
        }

        var headers: [String: String] = [:]
        httpResponse.allHeaderFields.forEach { key, value in
            guard let key = key as? String else {
                return
            }
            headers[key] = "\(value)"
        }

        return WebDAVTransportResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: data
        )
    }

    /// URLSession reports a cancelled trust challenge as a generic connection
    /// error; the delegate leaves the actionable decision in the recorder.
    private static func translatedError(
        _ error: Error,
        recorder: WebDAVServerTrustOutcomeRecorder
    ) -> Error {
        switch recorder.currentOutcome() {
        case .blocked(let challenge):
            if challenge.state == .mismatch {
                return WebDAVError.certificateFingerprintChanged(challenge)
            }
            return WebDAVError.untrustedCertificate(challenge)
        case .trustStoreUnavailable:
            return WebDAVError.certificateTrustStoreUnavailable
        case .inspectionFailed:
            return WebDAVError.certificateInspectionFailed
        case .systemTrusted, .pinned, .none:
            return error
        }
    }
}

public enum WebDAVError: Error, Sendable, Equatable, LocalizedError {
    case unexpectedStatus(operation: String, statusCode: Int)
    case integrityCheckFailed
    case nonHTTPResponse
    /// First connection to a self-signed / privately issued server: the user has
    /// to look at the fingerprint and confirm before anything is sent.
    case untrustedCertificate(WebDAVCertificateChallenge)
    /// The pinned fingerprint no longer matches. Never auto-accepted.
    case certificateFingerprintChanged(WebDAVCertificateChallenge)
    case certificateTrustStoreUnavailable
    case certificateInspectionFailed

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let operation, let statusCode):
            return "WebDAV \(operation) 失败，HTTP 状态码 \(statusCode)。"
        case .integrityCheckFailed:
            return "WebDAV 备份完整性校验失败。"
        case .nonHTTPResponse:
            return "WebDAV 服务器返回了非 HTTP 响应。"
        case .untrustedCertificate(let challenge):
            return "WebDAV 服务器证书未被系统信任（\(challenge.info.identity.displayAddress)）。SHA-256 指纹：\(challenge.info.displayFingerprint)。"
        case .certificateFingerprintChanged(let challenge):
            return "WebDAV 服务器证书指纹已变更，连接已阻止（\(challenge.info.identity.displayAddress)）。当前指纹：\(challenge.info.displayFingerprint)。"
        case .certificateTrustStoreUnavailable:
            return "无法读取 WebDAV 证书信任记录，已阻止连接。"
        case .certificateInspectionFailed:
            return "无法读取 WebDAV 服务器证书，已阻止连接。"
        }
    }
}

private extension WebDAVTransportResponse {
    func headerValue(_ name: String) -> String? {
        headers.first { key, _ in
            key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

private extension String {
    func matches(pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, range: range).compactMap { result in
            guard let matchRange = Range(result.range, in: self) else {
                return nil
            }
            return String(self[matchRange])
        }
    }

    func firstMatch(pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let result = regex.firstMatch(in: self, range: range),
              result.numberOfRanges > 1,
              let matchRange = Range(result.range(at: 1), in: self)
        else {
            return nil
        }
        return String(self[matchRange])
    }
}
