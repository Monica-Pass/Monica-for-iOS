// MARK: - Bitwarden 云保险库同步（BitwardenVaultSyncProvider / 传输 / 快照解析入口）

import Foundation

public protocol BitwardenVaultSyncTransport: Sendable {
    func send(_ request: BitwardenVaultSyncRequest) async throws -> BitwardenVaultSyncResponse
}

public struct BitwardenVaultSyncProvider: BitwardenSyncProvider {
    private let sessionStore: any BitwardenAuthenticationSessionStore
    private let accessTokenProvider: RefreshingBitwardenAccessTokenProvider
    private let vaultTransport: any BitwardenVaultSyncTransport
    private let vaultKeyStore: (any BitwardenVaultKeyStore)?

    public init(
        sessionStore: any BitwardenAuthenticationSessionStore,
        identityTransport: any BitwardenIdentityTokenTransport = URLSessionBitwardenIdentityTokenTransport(),
        vaultTransport: any BitwardenVaultSyncTransport = URLSessionBitwardenVaultSyncTransport(),
        vaultKeyStore: (any BitwardenVaultKeyStore)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sessionStore = sessionStore
        self.accessTokenProvider = RefreshingBitwardenAccessTokenProvider(
            sessionStore: sessionStore,
            identityTransport: identityTransport,
            now: now
        )
        self.vaultTransport = vaultTransport
        self.vaultKeyStore = vaultKeyStore
    }

    public func pullSnapshot() async throws -> BitwardenSyncSnapshot {
        guard let session = try sessionStore.loadSession() else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        let accessToken = try await accessTokenProvider.accessToken()
        let request = BitwardenVaultSyncRequest(
            method: "GET",
            url: Self.syncURL(apiURL: session.apiURL),
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json"
            ]
        )
        let response = try await vaultTransport.send(request)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        guard (200...299).contains(response.statusCode) else {
            throw BitwardenSyncProviderError.serverRejected(statusCode: response.statusCode)
        }
        return try BitwardenVaultSyncSnapshotParser.parse(
            response.body,
            fallbackAccountLabel: session.accountLabel,
            vaultKey: try vaultKeyStore?.loadVaultKey(accountLabel: session.accountLabel)
        )
    }

    /// 官方客户端同样用 `accounts/revision-date` 判断要不要重新拉取整个保险库。
    public func latestRevision() async throws -> BitwardenSyncRevision? {
        guard let session = try sessionStore.loadSession() else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        let accessToken = try await accessTokenProvider.accessToken()
        let response = try await vaultTransport.send(
            BitwardenVaultSyncRequest(
                method: "GET",
                url: Self.revisionDateURL(apiURL: session.apiURL),
                headers: [
                    "Authorization": "Bearer \(accessToken)",
                    "Accept": "application/json"
                ]
            )
        )
        if response.statusCode == 401 || response.statusCode == 403 {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        guard (200...299).contains(response.statusCode) else {
            throw BitwardenSyncProviderError.serverRejected(statusCode: response.statusCode)
        }
        return Self.parseRevision(data: response.body)
    }

    public func pullSnapshot(ifChangedSince revision: BitwardenSyncRevision?) async throws -> BitwardenSyncPullOutcome {
        guard let revision else {
            return .changed(snapshot: try await pullSnapshot(), revision: nil)
        }
        let latest = try await latestRevision()
        if let latest, latest.value == revision.value {
            return .unchanged(revision: latest)
        }
        return .changed(snapshot: try await pullSnapshot(), revision: latest)
    }

    public func pushMutations(_ mutations: [BitwardenSyncMutation]) async throws -> BitwardenSyncPushResult {
        guard let session = try sessionStore.loadSession() else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        guard !mutations.isEmpty else {
            let revision = String(session.expiresAt.timeIntervalSince1970)
            return BitwardenSyncPushResult(acceptedMutationCount: 0, conflicts: [], revision: revision)
        }
        let accessToken = try await accessTokenProvider.accessToken()
        let vaultKey = try vaultKeyStore?.loadVaultKey(accountLabel: session.accountLabel)
        var acceptedMutationCount = 0
        var latestRevision = ""
        var assignedRemoteIDs: [String: String] = [:]
        for mutation in mutations {
            if case .upsertFileSend = mutation {
                let fileSendResult = try await pushFileSendMutation(
                    mutation,
                    session: session,
                    accessToken: accessToken,
                    vaultKey: vaultKey
                )
                acceptedMutationCount += fileSendResult.acceptedMutationCount
                latestRevision = fileSendResult.revision.isEmpty ? latestRevision : fileSendResult.revision
                assignedRemoteIDs.merge(fileSendResult.assignedRemoteIDs) { _, new in new }
                continue
            }
            let response = try await vaultTransport.send(
                try Self.request(
                    for: mutation,
                    apiURL: session.apiURL,
                    accessToken: accessToken,
                    vaultKey: vaultKey
                )
            )
            if response.statusCode == 401 || response.statusCode == 403 {
                throw BitwardenSyncProviderError.authenticationRequired
            }
            if case .deleteSend = mutation, response.statusCode == 404 {
                acceptedMutationCount += 1
                continue
            }
            if case .deleteCipher = mutation, response.statusCode == 404 {
                acceptedMutationCount += 1
                continue
            }
            if case .permanentlyDeleteCipher = mutation, response.statusCode == 404 {
                acceptedMutationCount += 1
                continue
            }
            if case .restoreCipher = mutation,
               response.statusCode == 400 || response.statusCode == 404 {
                acceptedMutationCount += 1
                continue
            }
            if case .deleteFolder = mutation, response.statusCode == 404 {
                acceptedMutationCount += 1
                continue
            }
            guard (200...299).contains(response.statusCode) else {
                throw BitwardenSyncProviderError.serverRejected(statusCode: response.statusCode)
            }
            acceptedMutationCount += 1
            latestRevision = Self.revision(from: response) ?? latestRevision
            if let localID = Self.createdLocalID(for: mutation),
               let remoteID = Self.remoteID(from: response) {
                assignedRemoteIDs[localID] = remoteID
            }
        }
        return BitwardenSyncPushResult(
            acceptedMutationCount: acceptedMutationCount,
            conflicts: [],
            revision: latestRevision,
            assignedRemoteIDs: assignedRemoteIDs
        )
    }

    private func pushFileSendMutation(
        _ mutation: BitwardenSyncMutation,
        session: BitwardenAuthenticationSession,
        accessToken: String,
        vaultKey: BitwardenVaultKey?
    ) async throws -> BitwardenSyncPushResult {
        guard case .upsertFileSend(
            let localID,
            let remoteID,
            let title,
            let fileName,
            let fileContent,
            let mediaType,
            let notes,
            let expiresAt,
            let maxViews,
            let password,
            let hideEmail
        ) = mutation else {
            throw BitwardenSyncProviderError.unsupportedOperation
        }
        guard remoteID == nil else {
            throw BitwardenSyncProviderError.unsupportedOperation
        }
        guard let vaultKey else {
            throw BitwardenSyncProviderError.authenticationRequired
        }

        let keyMaterial = try BitwardenCrypto.makeSendKeyMaterial()
        let sendKey = try BitwardenCrypto.deriveSendKey(keyMaterial)
        let encryptedContent = try BitwardenCrypto.encryptSendFileContent(fileContent, key: sendKey)
        let normalizedExpirationDate = Self.normalizedBitwardenSendDate(expiresAt)
        let deletionDate = normalizedExpirationDate ?? "9999-12-31T00:00:00Z"
        let payload: [String: Any] = [
            "key": try BitwardenCrypto.encrypt(keyMaterial, key: vaultKey),
            "type": 1,
            "fileLength": encryptedContent.count,
            "name": try BitwardenCrypto.encryptString(title, key: sendKey),
            "notes": try notes.flatMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : try BitwardenCrypto.encryptString(value, key: sendKey)
            } ?? NSNull(),
            "password": try password.flatMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : try BitwardenCrypto.hashSendPassword(value, keyMaterial: keyMaterial)
            } ?? NSNull(),
            "disabled": false,
            "hideEmail": hideEmail,
            "deletionDate": deletionDate,
            "expirationDate": normalizedExpirationDate.map { $0 as Any } ?? NSNull(),
            "maxAccessCount": maxViews > 0 ? maxViews as Any : NSNull(),
            "file": [
                "fileName": try BitwardenCrypto.encryptString(fileName, key: sendKey)
            ]
        ]
        let createResponse = try await vaultTransport.send(
            BitwardenVaultSyncRequest(
                method: "POST",
                url: Self.sendFileURL(apiURL: session.apiURL),
                headers: Self.jsonHeaders(accessToken: accessToken),
                body: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            )
        )
        if createResponse.statusCode == 401 || createResponse.statusCode == 403 {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        guard (200...299).contains(createResponse.statusCode) else {
            throw BitwardenSyncProviderError.serverRejected(statusCode: createResponse.statusCode)
        }
        guard let root = try JSONSerialization.jsonObject(with: createResponse.body) as? [String: Any],
              let sendRemoteID = Self.jsonString(root, "id", "Id"),
              let file = (root["file"] as? [String: Any]) ?? (root["File"] as? [String: Any])
        else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        let uploadType = Self.jsonInt(file, "fileUploadType", "FileUploadType") ?? 0
        let fileID = Self.jsonString(file, "id", "Id")
        let uploadURL = try Self.fileSendUploadURL(
            apiURL: session.apiURL,
            file: file,
            sendRemoteID: sendRemoteID,
            fileID: fileID,
            uploadType: uploadType
        )
        let uploadResponse = try await vaultTransport.send(
            BitwardenVaultSyncRequest(
                method: uploadType == 1 ? "POST" : "PUT",
                url: uploadURL,
                headers: Self.fileUploadHeaders(
                    accessToken: accessToken,
                    mediaType: mediaType,
                    uploadType: uploadType
                ),
                body: encryptedContent
            )
        )
        guard (200...299).contains(uploadResponse.statusCode) else {
            throw BitwardenSyncProviderError.serverRejected(statusCode: uploadResponse.statusCode)
        }
        return BitwardenSyncPushResult(
            acceptedMutationCount: 1,
            revision: Self.revision(from: createResponse) ?? "",
            assignedRemoteIDs: [localID: sendRemoteID]
        )
    }

    static func revisionDateURL(apiURL: URL) -> URL {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + [basePath, "accounts", "revision-date"]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components?.queryItems = nil
        return components?.url ?? apiURL
    }

    /// 解析 `accounts/revision-date`：官方返回 `{"object":"template","data":<epoch 毫秒>}`，
    /// 部分自托管版本返回 ISO 8601 字符串。解析不了时返回 nil（调用方会退化为全量拉取）。
    static func parseRevision(data: Data) -> BitwardenSyncRevision? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let milliseconds = (root["data"] as? Double) ?? (root["Data"] as? Double) {
            return BitwardenSyncRevision(value: String(Int64(milliseconds)), capturedAt: Date(timeIntervalSince1970: milliseconds / 1000))
        }
        if let milliseconds = root["data"] as? Int {
            return BitwardenSyncRevision(value: String(milliseconds), capturedAt: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
        }
        if let raw = (root["data"] as? String) ?? (root["Data"] as? String), !raw.isEmpty {
            let capturedAt = ISO8601DateFormatter().date(from: raw)
            return BitwardenSyncRevision(value: raw, capturedAt: capturedAt ?? Date())
        }
        return nil
    }

    private static func syncURL(apiURL: URL) -> URL {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + ([basePath, "sync"].filter { !$0.isEmpty }).joined(separator: "/")
        components?.queryItems = [URLQueryItem(name: "excludeDomains", value: "true")]
        return components?.url ?? apiURL
    }

    private static func request(
        for mutation: BitwardenSyncMutation,
        apiURL: URL,
        accessToken: String,
        vaultKey: BitwardenVaultKey?
    ) throws -> BitwardenVaultSyncRequest {
        switch mutation {
        case .upsertFolder(_, let remoteID, let name):
            guard let vaultKey else {
                throw BitwardenSyncProviderError.authenticationRequired
            }
            let body = try JSONSerialization.data(
                withJSONObject: [
                    "name": try BitwardenCrypto.encryptString(name, key: vaultKey)
                ],
                options: [.sortedKeys]
            )
            return BitwardenVaultSyncRequest(
                method: remoteID == nil ? "POST" : "PUT",
                url: folderURL(apiURL: apiURL, remoteID: remoteID),
                headers: jsonHeaders(accessToken: accessToken),
                body: body
            )
        case .deleteFolder(_, let remoteID, _):
            guard let remoteID, !remoteID.isEmpty else {
                throw BitwardenSyncProviderError.unsupportedOperation
            }
            return BitwardenVaultSyncRequest(
                method: "DELETE",
                url: folderURL(apiURL: apiURL, remoteID: remoteID),
                headers: [
                    "Authorization": "Bearer \(accessToken)",
                    "Accept": "application/json"
                ]
            )
        case .upsertCipher(let item, let remoteID):
            guard let vaultKey else {
                throw BitwardenSyncProviderError.authenticationRequired
            }
            let body = try JSONSerialization.data(
                withJSONObject: encryptedCipherPayload(for: item, key: vaultKey),
                options: [.sortedKeys]
            )
            return BitwardenVaultSyncRequest(
                method: remoteID == nil ? "POST" : "PUT",
                url: cipherURL(apiURL: apiURL, remoteID: remoteID),
                headers: jsonHeaders(accessToken: accessToken),
                body: body
            )
        case .restoreCipher(_, let remoteID, _, _):
            guard let remoteID, !remoteID.isEmpty else {
                throw BitwardenSyncProviderError.unsupportedOperation
            }
            return BitwardenVaultSyncRequest(
                method: "PUT",
                url: cipherRestoreURL(apiURL: apiURL, remoteID: remoteID),
                headers: [
                    "Authorization": "Bearer \(accessToken)",
                    "Accept": "application/json"
                ]
            )
        case .deleteCipher(_, let remoteID, _, _):
            guard let remoteID, !remoteID.isEmpty else {
                throw BitwardenSyncProviderError.unsupportedOperation
            }
            return BitwardenVaultSyncRequest(
                method: "DELETE",
                url: cipherURL(apiURL: apiURL, remoteID: remoteID),
                headers: [
                    "Authorization": "Bearer \(accessToken)",
                    "Accept": "application/json"
                ]
            )
        case .permanentlyDeleteCipher(_, let remoteID, _, _):
            guard let remoteID, !remoteID.isEmpty else {
                throw BitwardenSyncProviderError.unsupportedOperation
            }
            return BitwardenVaultSyncRequest(
                method: "DELETE",
                url: cipherPermanentDeleteURL(apiURL: apiURL, remoteID: remoteID),
                headers: [
                    "Authorization": "Bearer \(accessToken)",
                    "Accept": "application/json"
                ]
            )
        case .upsertSend(_, let remoteID, let title, let body, let notes, let expiresAt, let maxViews):
            guard let vaultKey else {
                throw BitwardenSyncProviderError.authenticationRequired
            }
            let keyMaterial = try BitwardenCrypto.makeSendKeyMaterial()
            let sendKey = try BitwardenCrypto.deriveSendKey(keyMaterial)
            let normalizedExpirationDate = normalizedBitwardenSendDate(expiresAt)
            let deletionDate = normalizedExpirationDate ?? "9999-12-31T00:00:00Z"
            let payload: [String: Any] = [
                "key": try BitwardenCrypto.encrypt(keyMaterial, key: vaultKey),
                "type": 0,
                "name": try BitwardenCrypto.encryptString(title, key: sendKey),
                "notes": try notes.map { try BitwardenCrypto.encryptString($0, key: sendKey) } ?? NSNull(),
                "password": NSNull(),
                "disabled": false,
                "hideEmail": false,
                "deletionDate": deletionDate,
                "expirationDate": normalizedExpirationDate.map { $0 as Any } ?? NSNull(),
                "maxAccessCount": maxViews > 0 ? maxViews as Any : NSNull(),
                "text": [
                    "text": try BitwardenCrypto.encryptString(body, key: sendKey),
                    "hidden": false
                ]
            ]
            let body = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
            return BitwardenVaultSyncRequest(
                method: remoteID == nil ? "POST" : "PUT",
                url: sendURL(apiURL: apiURL, remoteID: remoteID),
                headers: jsonHeaders(accessToken: accessToken),
                body: body
            )
        case .upsertEncryptedSend(_, let remoteID, let key, let name, let notes, let text, let deletionDate, let expirationDate, let maxAccessCount):
            let payload: [String: Any] = [
                "key": key,
                "type": 0,
                "name": name,
                "notes": notes.map { $0 as Any } ?? NSNull(),
                "password": NSNull(),
                "disabled": false,
                "hideEmail": false,
                "deletionDate": deletionDate,
                "expirationDate": expirationDate.map { $0 as Any } ?? NSNull(),
                "maxAccessCount": maxAccessCount.map { $0 as Any } ?? NSNull(),
                "text": [
                    "text": text,
                    "hidden": false
                ]
            ]
            let body = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
            return BitwardenVaultSyncRequest(
                method: remoteID == nil ? "POST" : "PUT",
                url: sendURL(apiURL: apiURL, remoteID: remoteID),
                headers: jsonHeaders(accessToken: accessToken),
                body: body
            )
        case .upsertFileSend:
            throw BitwardenSyncProviderError.unsupportedOperation
        case .deleteSend(_, let remoteID, _):
            guard let remoteID, !remoteID.isEmpty else {
                throw BitwardenSyncProviderError.unsupportedOperation
            }
            return BitwardenVaultSyncRequest(
                method: "DELETE",
                url: sendURL(apiURL: apiURL, remoteID: remoteID),
                headers: [
                    "Authorization": "Bearer \(accessToken)",
                    "Accept": "application/json"
                ]
            )
        }
    }

    public func uploadAttachment(_ request: BitwardenAttachmentUploadRequest) async throws -> BitwardenAttachmentUploadResult {
        guard let session = try sessionStore.loadSession() else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        let accessToken = try await accessTokenProvider.accessToken()
        let planBody = try JSONSerialization.data(
            withJSONObject: [
                "fileName": request.encryptedFileName,
                "key": request.encryptedKey,
                "fileSize": request.originalByteCount
            ] as [String: Any],
            options: [.sortedKeys]
        )
        let planResponse = try await vaultTransport.send(
            BitwardenVaultSyncRequest(
                method: "POST",
                url: Self.attachmentPlanURL(apiURL: session.apiURL, cipherRemoteID: request.cipherRemoteID),
                headers: Self.jsonHeaders(accessToken: accessToken),
                body: planBody
            )
        )
        if planResponse.statusCode == 401 || planResponse.statusCode == 403 {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        guard (200...299).contains(planResponse.statusCode),
              let plan = try JSONSerialization.jsonObject(with: planResponse.body) as? [String: Any],
              let attachmentID = Self.jsonString(plan, "attachmentId", "AttachmentId"),
              let uploadURLString = Self.jsonString(plan, "url", "Url"),
              let uploadURL = URL(string: uploadURLString) else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        let uploadResponse = try await vaultTransport.send(
            BitwardenVaultSyncRequest(
                method: "PUT",
                url: uploadURL,
                headers: [
                    "Content-Type": request.mediaType.isEmpty ? "application/octet-stream" : request.mediaType
                ],
                body: request.encryptedContent
            )
        )
        guard (200...299).contains(uploadResponse.statusCode) else {
            throw BitwardenSyncProviderError.serverRejected(statusCode: uploadResponse.statusCode)
        }
        return BitwardenAttachmentUploadResult(
            attachmentRemoteID: attachmentID,
            encryptedByteCount: request.encryptedContent.count
        )
    }

    public func downloadAttachment(_ request: BitwardenAttachmentDownloadRequest) async throws -> BitwardenAttachmentDownloadResult {
        guard let session = try sessionStore.loadSession() else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        let accessToken = try await accessTokenProvider.accessToken()
        let response = try await vaultTransport.send(
            BitwardenVaultSyncRequest(
                method: "GET",
                url: Self.attachmentDownloadURL(
                    apiURL: session.apiURL,
                    cipherRemoteID: request.cipherRemoteID,
                    attachmentRemoteID: request.attachmentRemoteID
                ),
                headers: [
                    "Authorization": "Bearer \(accessToken)",
                    "Accept": "application/octet-stream"
                ]
            )
        )
        if response.statusCode == 401 || response.statusCode == 403 {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        guard (200...299).contains(response.statusCode) else {
            throw BitwardenSyncProviderError.serverRejected(statusCode: response.statusCode)
        }
        return BitwardenAttachmentDownloadResult(encryptedContent: response.body)
    }

    /// 创建文本型 Send。与通用 `.upsertSend` 路径的区别是：
    /// 这里保留 key material 并返回链接，通用路径会在加密后丢弃它。
    public func createTextSend(_ request: BitwardenTextSendCreateRequest) async throws -> BitwardenTextSendCreateResult {
        guard let session = try sessionStore.loadSession() else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        guard let vaultKey = try vaultKeyStore?.loadVaultKey(accountLabel: session.accountLabel) else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        let accessToken = try await accessTokenProvider.accessToken()

        let keyMaterial = try BitwardenCrypto.makeSendKeyMaterial()
        let sendKey = try BitwardenCrypto.deriveSendKey(keyMaterial)
        let normalizedExpiration = Self.normalizedBitwardenSendDate(request.expiresAt)
        let payload: [String: Any] = [
            "key": try BitwardenCrypto.encrypt(keyMaterial, key: vaultKey),
            "type": 0,
            "name": try BitwardenCrypto.encryptString(request.title, key: sendKey),
            "notes": try request.notes.flatMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return try BitwardenCrypto.encryptString(value, key: sendKey)
            } ?? NSNull(),
            "password": try request.password.flatMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return try BitwardenCrypto.hashSendPassword(value, keyMaterial: keyMaterial)
            } ?? NSNull(),
            "disabled": false,
            "hideEmail": request.hideEmail,
            "deletionDate": normalizedExpiration ?? "9999-12-31T00:00:00Z",
            "expirationDate": normalizedExpiration.map { $0 as Any } ?? NSNull(),
            "maxAccessCount": request.maxViews > 0 ? request.maxViews as Any : NSNull(),
            "text": [
                "text": try BitwardenCrypto.encryptString(request.text, key: sendKey),
                "hidden": false
            ]
        ]
        let response = try await vaultTransport.send(
            BitwardenVaultSyncRequest(
                method: "POST",
                url: Self.sendURL(apiURL: session.apiURL, remoteID: nil),
                headers: Self.jsonHeaders(accessToken: accessToken),
                body: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            )
        )
        if response.statusCode == 401 || response.statusCode == 403 {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        guard (200...299).contains(response.statusCode) else {
            throw BitwardenSyncProviderError.serverRejected(statusCode: response.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let remoteID = Self.jsonString(root, "id", "Id"),
              !remoteID.isEmpty
        else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        let accessID = Self.jsonString(root, "accessId", "AccessId") ?? ""
        let link = accessID.isEmpty
            ? nil
            : BitwardenSendLink(accessID: accessID, keyMaterial: keyMaterial)
        return BitwardenTextSendCreateResult(
            remoteID: remoteID,
            link: link,
            revision: Self.revision(from: response) ?? ""
        )
    }

    /// 匿名接收 Send：不携带 Bearer token，走 public access 端点。
    public func fetchSend(_ request: BitwardenSendFetchRequest) async throws -> BitwardenReceivedSend {
        var headers = ["Accept": "application/json"]
        // 有密码时必须先交换 access token，服务端返回的 send 才会带解密后的 payload。
        if let password = request.password?.trimmingCharacters(in: .whitespacesAndNewlines),
           !password.isEmpty {
            let passwordHash = try BitwardenCrypto.hashSendPassword(
                password,
                keyMaterial: request.link.keyMaterial
            )
            let passwordBody = try JSONSerialization.data(
                withJSONObject: ["password": passwordHash],
                options: [.sortedKeys]
            )
            let tokenResponse = try await vaultTransport.send(
                BitwardenVaultSyncRequest(
                    method: "POST",
                    url: Self.sendAccessPasswordURL(apiURL: request.apiURL, accessID: request.link.accessID),
                    headers: [
                        "Accept": "application/json",
                        "Content-Type": "application/json"
                    ],
                    body: passwordBody
                )
            )
            guard (200...299).contains(tokenResponse.statusCode) else {
                throw BitwardenSyncProviderError.serverRejected(statusCode: tokenResponse.statusCode)
            }
            guard let tokenRoot = try? JSONSerialization.jsonObject(with: tokenResponse.body) as? [String: Any],
                  let accessToken = Self.jsonString(tokenRoot, "token", "Token"),
                  !accessToken.isEmpty
            else {
                throw BitwardenSyncProviderError.invalidResponse
            }
            headers["Authorization"] = "Bearer \(accessToken)"
        }

        let response = try await vaultTransport.send(
            BitwardenVaultSyncRequest(
                method: "GET",
                url: Self.sendAccessURL(apiURL: request.apiURL, accessID: request.link.accessID),
                headers: headers
            )
        )
        if response.statusCode == 401 || response.statusCode == 403 {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        if response.statusCode == 404 {
            throw BitwardenSyncProviderError.sendUnavailable
        }
        guard (200...299).contains(response.statusCode) else {
            throw BitwardenSyncProviderError.serverRejected(statusCode: response.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw BitwardenSyncProviderError.invalidResponse
        }

        // key material 来自链接，直接派生 send key，不需服务端参与。
        let sendKey = try BitwardenCrypto.deriveSendKey(request.link.keyMaterial)
        let text = (root["text"] as? [String: Any]) ?? (root["Text"] as? [String: Any]) ?? [:]
        let name = Self.jsonString(root, "name", "Name")
        let notes = Self.jsonString(root, "notes", "Notes")

        let title = Self.decryptOptional(name, key: sendKey) ?? ""
        let body = try Self.decryptRequired(
            Self.jsonString(text, "text", "Text"),
            key: sendKey
        )

        return BitwardenReceivedSend(
            title: title,
            text: body,
            notes: Self.decryptOptional(notes, key: sendKey),
            expiresAt: Self.jsonString(root, "expirationDate", "ExpirationDate") ?? "",
            maxViews: Self.jsonInt(root, "maxAccessCount", "MaxAccessCount") ?? 1,
            remainingViews: Self.jsonInt(root, "accessCount", "AccessCount").map { accessed in
                let limit = Self.jsonInt(root, "maxAccessCount", "MaxAccessCount") ?? 1
                return Swift.max(0, limit - accessed)
            },
            requiresPassword: request.password?.isEmpty == false
        )
    }

    private static func decryptRequired(_ value: String?, key: BitwardenVaultKey) throws -> String {
        guard let value, !value.isEmpty else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        return try BitwardenCrypto.decryptString(value, key: key)
    }

    private static func decryptOptional(_ value: String?, key: BitwardenVaultKey) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return try? BitwardenCrypto.decryptString(value, key: key)
    }

    private static func sendAccessURL(apiURL: URL, accessID: String) -> URL {
        apiURL.appendingBitwardenPath("sends/access/\(accessID)")
    }

    private static func sendAccessPasswordURL(apiURL: URL, accessID: String) -> URL {
        apiURL.appendingBitwardenPath("sends/access/\(accessID)/password")
    }

    private static func sendURL(apiURL: URL, remoteID: String?) -> URL {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + ([basePath, "sends", remoteID].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }).joined(separator: "/")
        components?.queryItems = nil
        return components?.url ?? apiURL
    }

    private static func sendFileURL(apiURL: URL) -> URL {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + [basePath, "sends", "file", "v2"]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components?.queryItems = nil
        return components?.url ?? apiURL
    }

    private static func folderURL(apiURL: URL, remoteID: String?) -> URL {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + ([basePath, "folders", remoteID].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }).joined(separator: "/")
        components?.queryItems = nil
        return components?.url ?? apiURL
    }

    private static func fileSendUploadURL(
        apiURL: URL,
        file: [String: Any],
        sendRemoteID: String,
        fileID: String?,
        uploadType: Int
    ) throws -> URL {
        if uploadType == 0,
           let uploadURLString = jsonString(file, "url", "Url"),
           let uploadURL = URL(string: uploadURLString) {
            return uploadURL
        }
        guard uploadType == 1,
              let fileID,
              !fileID.isEmpty else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + [basePath, "sends", sendRemoteID, "file", fileID]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components?.queryItems = nil
        return components?.url ?? apiURL
    }

    private static func fileUploadHeaders(
        accessToken: String,
        mediaType: String,
        uploadType: Int
    ) -> [String: String] {
        if uploadType == 1 {
            return [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json",
                "Content-Type": mediaType.isEmpty ? "application/octet-stream" : mediaType
            ]
        }
        return ["Content-Type": "application/octet-stream"]
    }

    private static func normalizedBitwardenSendDate(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.contains("T") {
            return trimmed
        }
        return "\(trimmed)T00:00:00Z"
    }

    private static func cipherURL(apiURL: URL, remoteID: String?) -> URL {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + ([basePath, "ciphers", remoteID].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }).joined(separator: "/")
        components?.queryItems = nil
        return components?.url ?? apiURL
    }

    private static func cipherRestoreURL(apiURL: URL, remoteID: String) -> URL {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + [basePath, "ciphers", remoteID, "restore"]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components?.queryItems = nil
        return components?.url ?? apiURL
    }

    private static func cipherPermanentDeleteURL(apiURL: URL, remoteID: String) -> URL {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + [basePath, "ciphers", remoteID, "delete"]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components?.queryItems = nil
        return components?.url ?? apiURL
    }

    private static func attachmentPlanURL(apiURL: URL, cipherRemoteID: String) -> URL {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + [basePath, "ciphers", cipherRemoteID, "attachment", "v2"]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components?.queryItems = nil
        return components?.url ?? apiURL
    }

    private static func attachmentDownloadURL(apiURL: URL, cipherRemoteID: String, attachmentRemoteID: String) -> URL {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + [basePath, "ciphers", cipherRemoteID, "attachment", attachmentRemoteID]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components?.queryItems = nil
        return components?.url ?? apiURL
    }

    private static func encryptedCipherPayload(for item: BitwardenLocalItemSyncItem, key: BitwardenVaultKey) throws -> [String: Any] {
        var payload: [String: Any] = [
            "type": cipherType(for: item.kind),
            "name": try BitwardenCrypto.encryptString(item.title, key: key),
            "notes": try encryptedOptional(item.notes, key: key),
            "folderId": item.folderID.map { $0 as Any } ?? NSNull(),
            "favorite": item.favorite,
            "organizationId": item.organizationID.map { $0 as Any } ?? NSNull(),
            "collectionIds": item.collectionIDs
        ]

        switch item.kind {
        case .login, .passkey:
            var login: [String: Any] = [
                "username": try encryptedOptional(item.username, key: key),
                "password": try encryptedOptional(item.password, key: key),
                "totp": try encryptedOptional(item.totpSecret, key: key)
            ]
            if !item.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                login["uris"] = [
                    [
                        "uri": try BitwardenCrypto.encryptString(item.url, key: key),
                        "match": NSNull()
                    ]
                ]
            } else {
                login["uris"] = []
            }
            if item.kind == .passkey {
                login["fido2Credentials"] = [
                    try encryptedPasskeyCredentialPayload(for: item, key: key)
                ]
            }
            payload["login"] = login
        case .secureNote:
            payload["secureNote"] = ["type": 0]
        case .card:
            payload["card"] = [
                "cardholderName": try encryptedOptional(item.cardholderName, key: key),
                "number": try encryptedOptional(item.cardNumber, key: key),
                "expMonth": try encryptedOptional(item.cardExpiryMonth, key: key),
                "expYear": try encryptedOptional(item.cardExpiryYear, key: key),
                "code": try encryptedOptional(item.cardCode, key: key),
                "brand": try encryptedOptional(item.cardBrand, key: key)
            ]
        case .identity:
            payload["identity"] = [
                "firstName": try encryptedOptional(item.identityFullName, key: key),
                "passportNumber": try encryptedOptional(item.identityDocumentNumber, key: key),
                "company": try encryptedOptional(item.identityIssuer, key: key),
                "country": try encryptedOptional(item.identityCountry, key: key),
                "email": try encryptedOptional(item.username, key: key)
            ]
        case .sshKey:
            payload["sshKey"] = [
                "privateKey": try encryptedOptional(item.sshPrivateKey, key: key),
                "publicKey": try encryptedOptional(item.sshPublicKey, key: key),
                "keyFingerprint": try encryptedOptional(item.sshKeyFingerprint, key: key)
            ]
            payload["fields"] = try encryptedSshKeyCompatibilityFields(for: item, key: key)
        }

        return payload
    }

    private static func encryptedSshKeyCompatibilityFields(for item: BitwardenLocalItemSyncItem, key: BitwardenVaultKey) throws -> [[String: Any]] {
        var fields: [(name: String, value: String, type: Int)] = [
            ("monica_login_type", "SSH_KEY", 0)
        ]
        if let publicKey = nonBlank(item.sshPublicKey) {
            fields.append(("monica_ssh_public_key", publicKey, 0))
        }
        if let privateKey = nonBlank(item.sshPrivateKey) {
            fields.append(("monica_ssh_private_key", privateKey, 1))
        }
        if let fingerprint = nonBlank(item.sshKeyFingerprint) {
            fields.append(("monica_ssh_fingerprint", fingerprint, 0))
        }

        return try fields.map { field in
            [
                "type": field.type,
                "name": try BitwardenCrypto.encryptString(field.name, key: key),
                "value": try BitwardenCrypto.encryptString(field.value, key: key)
            ]
        }
    }

    private static func encryptedPasskeyCredentialPayload(for item: BitwardenLocalItemSyncItem, key: BitwardenVaultKey) throws -> [String: Any] {
        [
            "credentialId": try encryptedOptional(item.passkeyCredentialID, key: key),
            "keyType": try encryptedOptional("public-key", key: key),
            "keyAlgorithm": try encryptedOptional(item.passkeyPublicKeyAlgorithm.isEmpty ? "ECDSA" : item.passkeyPublicKeyAlgorithm, key: key),
            "keyCurve": try encryptedOptional("P-256", key: key),
            "keyValue": try encryptedOptional(item.passkeyPrivateKeyReference, key: key),
            "rpId": try encryptedOptional(item.passkeyRelyingPartyID, key: key),
            "rpName": try encryptedOptional(item.passkeyRelyingPartyName.isEmpty ? item.title : item.passkeyRelyingPartyName, key: key),
            "counter": try encryptedOptional(item.passkeyCounter.isEmpty ? "0" : item.passkeyCounter, key: key),
            "userHandle": try encryptedOptional(item.passkeyUserHandle, key: key),
            "userName": try encryptedOptional(item.username, key: key),
            "userDisplayName": try encryptedOptional(item.username, key: key),
            "discoverable": try encryptedOptional(item.passkeyDiscoverable ? "true" : "false", key: key),
            "creationDate": item.passkeyCreationDate.isEmpty ? ISO8601DateFormatter().string(from: Date()) : item.passkeyCreationDate
        ]
    }

    private static func encryptedOptional(_ value: String?, key: BitwardenVaultKey) throws -> Any {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return NSNull()
        }
        return try BitwardenCrypto.encryptString(value, key: key)
    }

    private static func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private static func cipherType(for kind: BitwardenSyncItemKind) -> Int {
        switch kind {
        case .login, .passkey:
            1
        case .secureNote:
            2
        case .card:
            3
        case .identity:
            4
        case .sshKey:
            5
        }
    }

    private static func jsonHeaders(accessToken: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "Content-Type": "application/json"
        ]
    }

    private static func revision(from response: BitwardenVaultSyncResponse) -> String? {
        guard !response.body.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else {
            return response.headers["ETag"]
        }
        return jsonString(root, "revisionDate", "RevisionDate") ?? response.headers["ETag"]
    }

    private static func remoteID(from response: BitwardenVaultSyncResponse) -> String? {
        guard !response.body.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else {
            return nil
        }
        return jsonString(root, "id", "Id")
    }

    private static func createdLocalID(for mutation: BitwardenSyncMutation) -> String? {
        switch mutation {
        case .upsertFolder(let localID, let remoteID, _):
            remoteID == nil ? localID : nil
        case .upsertCipher(let item, let remoteID):
            remoteID == nil ? item.localID : nil
        case .upsertSend(let localID, let remoteID, _, _, _, _, _):
            remoteID == nil ? localID : nil
        case .upsertEncryptedSend(let localID, let remoteID, _, _, _, _, _, _, _):
            remoteID == nil ? localID : nil
        case .upsertFileSend(let localID, let remoteID, _, _, _, _, _, _, _, _, _):
            remoteID == nil ? localID : nil
        case .deleteFolder, .restoreCipher, .deleteCipher, .permanentlyDeleteCipher, .deleteSend:
            nil
        }
    }

    private static func jsonString(_ json: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = json[key] as? String {
                return value
            }
            if let number = json[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private static func jsonInt(_ json: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let value = json[key] as? Int {
                return value
            }
            if let value = json[key] as? Double {
                return Int(value)
            }
            if let number = json[key] as? NSNumber {
                return number.intValue
            }
            if let value = json[key] as? String, let intValue = Int(value) {
                return intValue
            }
        }
        return nil
    }
}

public final class URLSessionBitwardenVaultSyncTransport: BitwardenVaultSyncTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: BitwardenVaultSyncRequest) async throws -> BitwardenVaultSyncResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        request.headers.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = request.body
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BitwardenSyncProviderError.unsupportedOperation
        }
        var headers: [String: String] = [:]
        httpResponse.allHeaderFields.forEach { key, value in
            guard let key = key as? String else { return }
            headers[key] = "\(value)"
        }
        return BitwardenVaultSyncResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: data
        )
    }
}
