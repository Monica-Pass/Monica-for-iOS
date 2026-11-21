import Foundation

// MARK: - Cloud vault remote adapters (issue #31)
//
// `CloudVaultRemoteStore` is the only seam between the sync engine and a concrete
// cloud backend. This file ships the two MVP adapters:
//
// * `WebDAVCloudVaultRemoteStore` – a WebDAV directory holding two objects
//   (vault bytes + `CloudVaultManifest` commit marker), driven by the existing
//   `WebDAVTransport` abstraction so it never owns URLSession directly;
// * `CloudFileCloudVaultRemoteStore` – the same two-object layout on top of any
//   `CloudFileProvider` (the OneDrive app folder in practice).
//
// Both adapters follow the same rules:
//
// 1. the vault bytes are written before the manifest, so a partially failed write
//    never advertises bytes that are not actually remote;
// 2. the manifest is only trusted after the downloaded bytes match its SHA-256
//    and byte count;
// 3. writes are conditional whenever the backend exposes an ETag/revision, and the
//    WebDAV adapter refuses the write by re-reading the manifest when it does not;
// 4. no vault bytes, credentials or secrets are ever logged or embedded in errors.

// MARK: - Shared helpers

private let cloudVaultDefaultFileName = "monica-vault.mdbx"
private let cloudVaultServerMessageLimit = 200

/// The `WebDAVTransport` protocol is not annotated `Sendable`, so the existential is
/// kept in a box that opts out of the stored-property check. Every concrete
/// transport used in production (`URLSessionWebDAVTransport`) is thread safe.
private struct WebDAVTransportBox: @unchecked Sendable {
    let transport: any WebDAVTransport
}

func cloudVaultSHA256Hex(_ data: Data) -> String {
    LanSyncEncoding.hex(LanSyncEncoding.sha256(data))
}

/// Verifies vault bytes (upload or download) against the manifest digest that pins
/// them. Shared by every adapter, including the CloudKit one in
/// `CloudKitVaultRemoteStore.swift`.
///
func verifyCloudVaultIntegrity(_ data: Data, manifest: CloudVaultManifest) throws {
    let actualSHA256 = cloudVaultSHA256Hex(data)
    guard data.count == manifest.byteCount, actualSHA256 == manifest.contentSHA256 else {
        throw CloudVaultError.integrityMismatch(
            expectedSHA256: manifest.contentSHA256,
            actualSHA256: actualSHA256
        )
    }
}

/// Case-insensitive header lookup; returns `nil` for blank values.
private func webDAVHeaderValue(_ name: String, in headers: [String: String]) -> String? {
    for (key, value) in headers where key.caseInsensitiveCompare(name) == .orderedSame {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    return nil
}

/// ETags are opaque: keep the exact value, quotes included, so `If-Match` can
/// replay it verbatim.
private func webDAVETag(in headers: [String: String]) -> String? {
    webDAVHeaderValue("ETag", in: headers)
}

/// Server bodies are diagnostics only; collapse them to a short single line so a
/// hostile or chatty backend cannot flood the UI (or leak a huge payload into a
/// persisted `CloudVaultSyncRecord.lastFailureMessage`).
private func truncatedWebDAVMessage(_ body: Data, statusCode: Int) -> String {
    let text = String(data: body, encoding: .utf8) ?? ""
    let collapsed = text
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    guard !collapsed.isEmpty else { return "HTTP \(statusCode)" }
    guard collapsed.count > cloudVaultServerMessageLimit else { return collapsed }
    return String(collapsed.prefix(cloudVaultServerMessageLimit)) + "…"
}

/// Maps a non-success WebDAV status onto the cloud vault error surface.
private func webDAVCloudVaultError(
    statusCode: Int,
    response: WebDAVTransportResponse,
    kind: CloudVaultRemoteKind,
    notFound: CloudVaultError
) -> CloudVaultError {
    switch statusCode {
    case 401:
        return .unauthorized(kind)
    case 403:
        return .forbidden(kind)
    case 404, 410:
        return notFound
    case 409, 412:
        return .preconditionFailed(remoteRevision: webDAVETag(in: response.headers))
    default:
        return .server(
            statusCode: statusCode,
            message: truncatedWebDAVMessage(response.body, statusCode: statusCode)
        )
    }
}

// MARK: - WebDAV

/// `CloudVaultRemoteStore` backed by a plain WebDAV directory.
///
/// Every request carries Basic auth and addresses `<baseURL>/<fileName>` through
/// `WebDAVEndpoint.url(for:)`, matching the existing backup client's conventions.
public struct WebDAVCloudVaultRemoteStore: CloudVaultRemoteStore {
    public let kind: CloudVaultRemoteKind = .webDAV
    public let displayName: String = "WebDAV 备份目录"

    /// Sanitised vault file name; also the identity of the sync record.
    public let remotePath: String

    private let manifestFileName: String
    private let endpoint: WebDAVEndpoint
    private let transportBox: WebDAVTransportBox
    /// Injected clock. No adapter code path stamps its own timestamps today
    /// (conflict-copy naming receives the explicit `now:` date from the protocol),
    /// but keeping the clock here lets callers pin time deterministically.
    private let clock: @Sendable () -> Date

    public init(
        endpoint: WebDAVEndpoint,
        vaultFileName: String,
        transport: (any WebDAVTransport)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let sanitized = CloudVaultNaming.sanitizedFileName(
            vaultFileName,
            fallback: cloudVaultDefaultFileName
        )
        self.endpoint = endpoint
        self.remotePath = sanitized
        self.manifestFileName = CloudVaultNaming.manifestFileName(forVaultFileName: sanitized)
        self.transportBox = WebDAVTransportBox(
            transport: transport ?? URLSessionWebDAVTransport(identity: WebDAVTrustIdentity(endpoint: endpoint))
        )
        self.clock = now
    }

    // MARK: Reading

    public func readRemote() async throws -> CloudVaultRemoteFile? {
        let manifestResponse = try await send(
            WebDAVTransportRequest(
                method: "GET",
                url: endpoint.url(for: manifestFileName),
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Accept": "application/json"
                ]
            )
        )

        switch manifestResponse.statusCode {
        case 200:
            break
        case 404, 410:
            // No commit marker: from the sync engine's point of view the remote
            // vault simply does not exist yet, even if a stray vault file is there.
            return nil
        default:
            throw webDAVCloudVaultError(
                statusCode: manifestResponse.statusCode,
                response: manifestResponse,
                kind: kind,
                notFound: .remoteManifestMissing
            )
        }

        guard manifestResponse.body.count <= CloudVaultProtocolSpec.maxManifestBytes else {
            throw CloudVaultError.manifestInvalid(
                reason: "清单文件过大（\(manifestResponse.body.count) 字节）"
            )
        }
        let manifest = try CloudVaultManifest.decode(manifestResponse.body)
        let manifestETag = webDAVETag(in: manifestResponse.headers)

        // HEAD is enough to learn the vault ETag (for `If-Match`) without pulling
        // the full vault down twice.
        let headResponse = try await send(
            WebDAVTransportRequest(
                method: "HEAD",
                url: endpoint.url(for: remotePath),
                headers: ["Authorization": endpoint.authorizationHeader]
            )
        )

        switch headResponse.statusCode {
        case 200..<300:
            break
        case 401:
            // A manifest we just read proves the credentials work for reads; an
            // auth failure on the vault means the server actually refused the file,
            // which is worth surfacing instead of "vault missing".
            throw CloudVaultError.unauthorized(kind)
        case 403:
            throw CloudVaultError.forbidden(kind)
        default:
            throw CloudVaultError.remoteVaultMissing
        }

        if let contentLength = webDAVHeaderValue("Content-Length", in: headResponse.headers),
           let declaredBytes = Int(contentLength),
           declaredBytes != manifest.byteCount {
            throw CloudVaultError.manifestInvalid(
                reason: "云端保险库文件大小（\(declaredBytes) 字节）与清单记录（\(manifest.byteCount) 字节）不一致"
            )
        }

        return CloudVaultRemoteFile(
            kind: kind,
            remotePath: remotePath,
            fileName: remotePath,
            manifestFileName: manifestFileName,
            itemID: nil,
            revision: webDAVETag(in: headResponse.headers),
            manifestRevision: manifestETag,
            manifest: manifest
        )
    }

    public func downloadVault(_ remote: CloudVaultRemoteFile) async throws -> Data {
        let response = try await send(
            WebDAVTransportRequest(
                method: "GET",
                url: endpoint.url(for: remotePath),
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Accept": "application/octet-stream"
                ]
            )
        )

        guard response.statusCode == 200 else {
            throw webDAVCloudVaultError(
                statusCode: response.statusCode,
                response: response,
                kind: kind,
                notFound: .remoteVaultMissing
            )
        }
        guard response.body.count <= CloudVaultProtocolSpec.maxVaultBytes else {
            throw CloudVaultError.vaultTooLarge(byteCount: response.body.count)
        }
        try verifyCloudVaultIntegrity(response.body, manifest: remote.manifest)
        return response.body
    }

    // MARK: Creating

    public func createRemote(
        vaultData: Data,
        manifest: CloudVaultManifest
    ) async throws -> CloudVaultWriteReceipt {
        // `If-None-Match: *` turns a lost race (another device published a vault
        // between our read and this write) into a precondition failure instead of a
        // silent overwrite.
        let vaultResponse = try await putVault(vaultData, ifNoneMatch: "*")
        try failUnlessSuccessful(vaultResponse, notFound: .remoteVaultMissing)
        let vaultETag = webDAVETag(in: vaultResponse.headers)

        // The manifest is published with the same "create only" precondition so two
        // devices racing to initialise the same folder cannot end up with a manifest
        // describing the loser's bytes.
        let manifestResponse = try await putManifest(
            try manifest.encodedData(),
            ifNoneMatch: "*"
        )
        // The vault bytes are already remote while the commit marker is not. A vault
        // file without its manifest is reported as "no remote vault" by
        // `readRemote()`, so the orphan is harmless: the next attempt rewrites both
        // objects (the vault PUT is conditional, so it still cannot clobber another
        // device's newer vault). Rethrow the mapped error unchanged.
        try failUnlessSuccessful(manifestResponse, notFound: .remoteManifestMissing)

        return CloudVaultWriteReceipt(
            kind: kind,
            remotePath: remotePath,
            fileName: remotePath,
            manifestFileName: manifestFileName,
            itemID: nil,
            revision: vaultETag,
            manifestRevision: webDAVETag(in: manifestResponse.headers),
            manifest: manifest
        )
    }

    // MARK: Updating

    public func updateRemote(
        vaultData: Data,
        manifest: CloudVaultManifest,
        remote: CloudVaultRemoteFile
    ) async throws -> CloudVaultWriteReceipt {
        let manifestData = try manifest.encodedData()

        if let expectedRevision = remote.revision, !expectedRevision.isEmpty {
            let vaultResponse = try await putVault(vaultData, ifMatch: expectedRevision)
            try failUnlessSuccessful(vaultResponse, notFound: .remoteVaultMissing)
            let vaultETag = webDAVETag(in: vaultResponse.headers)

            // Manifest last: a failure here leaves the previous manifest pointing at
            // older bytes, which the next read detects as a stale/!matching digest
            // instead of advertising an unverifiable vault.
            let manifestResponse = try await putManifest(
                manifestData,
                ifMatch: remote.manifestRevision,
                ifNoneMatch: nil
            )
            try failUnlessSuccessful(manifestResponse, notFound: .remoteManifestMissing)

            return CloudVaultWriteReceipt(
                kind: kind,
                remotePath: remotePath,
                fileName: remotePath,
                manifestFileName: manifestFileName,
                itemID: nil,
                revision: vaultETag,
                manifestRevision: webDAVETag(in: manifestResponse.headers),
                manifest: manifest
            )
        }

        // Conservative fallback for servers that expose no vault ETag: re-read the
        // manifest and refuse when its revision moved since the caller's read. This
        // narrows (but cannot fully close) the race window; the manifest PUT below
        // stays conditional whenever the server did expose a manifest ETag.
        let current = try await readManifest()
        guard current.manifest.revision == remote.manifest.revision else {
            throw CloudVaultError.preconditionFailed(remoteRevision: current.etag)
        }

        let vaultResponse = try await putVault(vaultData)
        try failUnlessSuccessful(vaultResponse, notFound: .remoteVaultMissing)
        let vaultETag = webDAVETag(in: vaultResponse.headers)

        let manifestResponse = try await putManifest(
            manifestData,
            ifMatch: remote.manifestRevision,
            ifNoneMatch: nil
        )
        try failUnlessSuccessful(manifestResponse, notFound: .remoteManifestMissing)

        return CloudVaultWriteReceipt(
            kind: kind,
            remotePath: remotePath,
            fileName: remotePath,
            manifestFileName: manifestFileName,
            itemID: nil,
            revision: vaultETag,
            manifestRevision: webDAVETag(in: manifestResponse.headers),
            manifest: manifest
        )
    }

    // MARK: Conflict copies

    public func writeConflictCopy(
        vaultData: Data,
        manifest: CloudVaultManifest,
        deviceName: String,
        now: Date
    ) async throws -> CloudVaultWriteReceipt {
        // Deterministic name: a retry of the same resolution produces the same file
        // name instead of spamming the folder with near-identical copies.
        let token = CloudVaultNaming.conflictCopyToken(sha256: manifest.contentSHA256, date: now)
        let copyName = CloudVaultNaming.conflictCopyFileName(
            vaultFileName: remotePath,
            deviceName: deviceName,
            date: now,
            shortToken: token
        )

        // `If-None-Match: *` is the important part: this must never overwrite a
        // vault, a conflict copy, or a file another device happened to create.
        let response = try await putVault(vaultData, fileName: copyName, ifNoneMatch: "*")
        try failUnlessSuccessful(response, notFound: .remoteVaultMissing)

        return CloudVaultWriteReceipt(
            kind: kind,
            remotePath: remotePath,
            fileName: copyName,
            manifestFileName: manifestFileName,
            itemID: nil,
            revision: webDAVETag(in: response.headers),
            manifestRevision: nil,
            manifest: manifest
        )
    }

    // MARK: Request plumbing

    private func send(_ request: WebDAVTransportRequest) async throws -> WebDAVTransportResponse {
        do {
            return try await transportBox.transport.send(request)
        } catch let error as CloudVaultError {
            throw error
        } catch {
            throw CloudVaultError.network(error.localizedDescription)
        }
    }

    private func putVault(
        _ vaultData: Data,
        fileName: String? = nil,
        ifMatch: String? = nil,
        ifNoneMatch: String? = nil
    ) async throws -> WebDAVTransportResponse {
        var headers = [
            "Authorization": endpoint.authorizationHeader,
            "Content-Type": "application/octet-stream"
        ]
        if let ifMatch, !ifMatch.isEmpty {
            headers["If-Match"] = ifMatch
        }
        if let ifNoneMatch {
            headers["If-None-Match"] = ifNoneMatch
        }
        return try await send(
            WebDAVTransportRequest(
                method: "PUT",
                url: endpoint.url(for: fileName ?? remotePath),
                headers: headers,
                body: vaultData
            )
        )
    }

    private func putManifest(
        _ manifestData: Data,
        ifMatch: String? = nil,
        ifNoneMatch: String? = nil
    ) async throws -> WebDAVTransportResponse {
        var headers = [
            "Authorization": endpoint.authorizationHeader,
            "Content-Type": "application/json"
        ]
        if let ifMatch, !ifMatch.isEmpty {
            headers["If-Match"] = ifMatch
        }
        if let ifNoneMatch {
            headers["If-None-Match"] = ifNoneMatch
        }
        return try await send(
            WebDAVTransportRequest(
                method: "PUT",
                url: endpoint.url(for: manifestFileName),
                headers: headers,
                body: manifestData
            )
        )
    }

    /// Re-reads the manifest (used by the no-ETag fallback in `updateRemote`).
    private func readManifest() async throws -> (manifest: CloudVaultManifest, etag: String?) {
        let response = try await send(
            WebDAVTransportRequest(
                method: "GET",
                url: endpoint.url(for: manifestFileName),
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Accept": "application/json"
                ]
            )
        )
        guard response.statusCode == 200 else {
            throw webDAVCloudVaultError(
                statusCode: response.statusCode,
                response: response,
                kind: kind,
                notFound: .remoteManifestMissing
            )
        }
        guard response.body.count <= CloudVaultProtocolSpec.maxManifestBytes else {
            throw CloudVaultError.manifestInvalid(reason: "清单文件过大（\(response.body.count) 字节）")
        }
        return (try CloudVaultManifest.decode(response.body), webDAVETag(in: response.headers))
    }

    private func failUnlessSuccessful(
        _ response: WebDAVTransportResponse,
        notFound: CloudVaultError
    ) throws {
        if [200, 201, 204].contains(response.statusCode) {
            return
        }
        throw webDAVCloudVaultError(
            statusCode: response.statusCode,
            response: response,
            kind: kind,
            notFound: notFound
        )
    }
}

// MARK: - CloudFileProvider (OneDrive)

/// `CloudVaultRemoteStore` for the OneDrive app folder, expressed entirely through
/// `CloudFileProvider` so the Graph/MSAL specifics stay in one place.
///
/// The frozen `CloudVaultRemoteKind` only knows WebDAV and OneDrive, so this adapter
/// always advertises `.oneDrive`; a provider of any other kind is refused by every
/// method with `CloudVaultError.unsupportedProvider`.
public struct CloudFileCloudVaultRemoteStore: CloudVaultRemoteStore {
    /// `CloudVaultRemoteKind` has no Google Drive case, so the only vault kind this
    /// adapter can advertise is `.oneDrive`. Providers of another kind are rejected
    /// up front by `ensureSupported()`.
    public var kind: CloudVaultRemoteKind { .oneDrive }
    public let displayName: String = "OneDrive 应用文件夹"

    public let remotePath: String

    private let manifestFileName: String
    private let provider: any CloudFileProvider
    /// `CloudFileProviderKind` of the wrapped provider, captured at init so every
    /// method can refuse unsupported backends before touching the network.
    private let providerKind: CloudFileProviderKind

    public init(provider: any CloudFileProvider, vaultFileName: String) {
        let sanitized = CloudVaultNaming.sanitizedFileName(
            vaultFileName,
            fallback: cloudVaultDefaultFileName
        )
        self.provider = provider
        self.providerKind = provider.kind
        self.remotePath = sanitized
        self.manifestFileName = CloudVaultNaming.manifestFileName(forVaultFileName: sanitized)
    }

    // MARK: Reading

    public func readRemote() async throws -> CloudVaultRemoteFile? {
        try ensureSupported()

        let items = try await listItems()
        guard let manifestItem = items.first(where: { $0.name == manifestFileName }) else {
            // Without the commit marker the remote vault is treated as absent even
            // if a stray vault file is present.
            return nil
        }

        let manifestDownload: CloudFileDownload
        do {
            manifestDownload = try await provider.downloadFile(id: manifestItem.id)
        } catch {
            throw mapProviderError(error, notFound: .remoteManifestMissing)
        }
        guard manifestDownload.data.count <= CloudVaultProtocolSpec.maxManifestBytes else {
            throw CloudVaultError.manifestInvalid(
                reason: "清单文件过大（\(manifestDownload.data.count) 字节）"
            )
        }
        let manifest = try CloudVaultManifest.decode(manifestDownload.data)

        guard let vaultItem = items.first(where: { $0.name == remotePath }) else {
            throw CloudVaultError.remoteVaultMissing
        }
        // A zero byte count means the provider did not report a size; the digest
        // check in `downloadVault` remains authoritative either way.
        if vaultItem.byteCount > 0, vaultItem.byteCount != manifest.byteCount {
            throw CloudVaultError.manifestInvalid(
                reason: "云端保险库文件大小（\(vaultItem.byteCount) 字节）与清单记录（\(manifest.byteCount) 字节）不一致"
            )
        }

        return CloudVaultRemoteFile(
            kind: kind,
            remotePath: remotePath,
            fileName: remotePath,
            manifestFileName: manifestFileName,
            itemID: vaultItem.id,
            revision: vaultItem.revision,
            manifestRevision: manifestItem.revision,
            manifest: manifest
        )
    }

    public func downloadVault(_ remote: CloudVaultRemoteFile) async throws -> Data {
        try ensureSupported()
        guard let itemID = remote.itemID else {
            // Item IDs are the only stable handle a Graph provider offers; without
            // one there is nothing trustworthy to download.
            throw CloudVaultError.remoteVaultMissing
        }

        let download: CloudFileDownload
        do {
            download = try await provider.downloadFile(id: itemID)
        } catch {
            throw mapProviderError(error, notFound: .remoteVaultMissing)
        }
        guard download.data.count <= CloudVaultProtocolSpec.maxVaultBytes else {
            throw CloudVaultError.vaultTooLarge(byteCount: download.data.count)
        }
        // Never trust the provider-reported digest: recompute from the bytes.
        try verifyCloudVaultIntegrity(download.data, manifest: remote.manifest)
        return download.data
    }

    // MARK: Creating

    public func createRemote(
        vaultData: Data,
        manifest: CloudVaultManifest
    ) async throws -> CloudVaultWriteReceipt {
        try ensureSupported()

        // `uploadFile` is an unconditional PUT, so the existence check is the only
        // guard against clobbering another device's vault. Check both objects.
        let items = try await listItems()
        if let existing = items.first(where: { $0.name == remotePath || $0.name == manifestFileName }) {
            throw CloudVaultError.preconditionFailed(remoteRevision: existing.revision)
        }

        let vaultReceipt: CloudFileWriteReceipt
        do {
            vaultReceipt = try await provider.uploadFile(named: remotePath, data: vaultData)
        } catch {
            throw mapProviderError(error, notFound: .remoteVaultMissing)
        }

        let manifestData = try manifest.encodedData()
        let manifestReceipt: CloudFileWriteReceipt
        do {
            manifestReceipt = try await provider.uploadFile(named: manifestFileName, data: manifestData)
        } catch {
            // The vault file is remote without its commit marker, which
            // `readRemote()` reports as "no remote vault". That orphan is harmless:
            // the next attempt re-enters `createRemote` and overwrites both objects.
            throw mapProviderError(error, notFound: .remoteManifestMissing)
        }

        return CloudVaultWriteReceipt(
            kind: kind,
            remotePath: remotePath,
            fileName: remotePath,
            manifestFileName: manifestFileName,
            itemID: vaultReceipt.itemID,
            revision: vaultReceipt.revision,
            manifestRevision: manifestReceipt.revision,
            manifest: manifest
        )
    }

    // MARK: Updating

    public func updateRemote(
        vaultData: Data,
        manifest: CloudVaultManifest,
        remote: CloudVaultRemoteFile
    ) async throws -> CloudVaultWriteReceipt {
        try ensureSupported()
        guard let itemID = remote.itemID else {
            throw CloudVaultError.remoteVaultMissing
        }

        let vaultReceipt: CloudFileWriteReceipt
        do {
            vaultReceipt = try await provider.overwriteFile(
                id: itemID,
                data: vaultData,
                fileName: remotePath,
                expectedRevision: remote.revision
            )
        } catch {
            throw mapProviderError(error, notFound: .remoteVaultMissing)
        }

        // The manifest item ID is not part of `CloudVaultRemoteFile`, so re-list to
        // find it; its revision from the read is still used as `expectedRevision`.
        let items = try await listItems()
        guard let manifestItem = items.first(where: { $0.name == manifestFileName }) else {
            throw CloudVaultError.remoteManifestMissing
        }

        let manifestData = try manifest.encodedData()
        let manifestReceipt: CloudFileWriteReceipt
        do {
            // Manifest last: a failure here leaves the old commit marker in place.
            manifestReceipt = try await provider.overwriteFile(
                id: manifestItem.id,
                data: manifestData,
                fileName: manifestFileName,
                expectedRevision: remote.manifestRevision
            )
        } catch {
            throw mapProviderError(error, notFound: .remoteManifestMissing)
        }

        return CloudVaultWriteReceipt(
            kind: kind,
            remotePath: remotePath,
            fileName: remotePath,
            manifestFileName: manifestFileName,
            itemID: vaultReceipt.itemID,
            revision: vaultReceipt.revision,
            manifestRevision: manifestReceipt.revision,
            manifest: manifest
        )
    }

    // MARK: Conflict copies

    public func writeConflictCopy(
        vaultData: Data,
        manifest: CloudVaultManifest,
        deviceName: String,
        now: Date
    ) async throws -> CloudVaultWriteReceipt {
        try ensureSupported()

        let token = CloudVaultNaming.conflictCopyToken(sha256: manifest.contentSHA256, date: now)
        let baseName = CloudVaultNaming.conflictCopyFileName(
            vaultFileName: remotePath,
            deviceName: deviceName,
            date: now,
            shortToken: token
        )

        let existingNames = Set(try await listItems().map { $0.name })
        guard let copyName = Self.uniqueConflictCopyName(baseName, existingNames: existingNames) else {
            throw CloudVaultError.preconditionFailed(remoteRevision: nil)
        }

        let receipt: CloudFileWriteReceipt
        do {
            receipt = try await provider.uploadFile(named: copyName, data: vaultData)
        } catch {
            throw mapProviderError(error, notFound: .remoteVaultMissing)
        }

        return CloudVaultWriteReceipt(
            kind: kind,
            remotePath: remotePath,
            fileName: copyName,
            manifestFileName: manifestFileName,
            itemID: receipt.itemID,
            revision: receipt.revision,
            manifestRevision: nil,
            manifest: manifest
        )
    }

    /// Deterministic first choice, then `-1` … `-8` so a copy that already exists
    /// (e.g. a retried resolution) is never overwritten.
    private static func uniqueConflictCopyName(_ baseName: String, existingNames: Set<String>) -> String? {
        guard existingNames.contains(baseName) else { return baseName }
        for index in 1...8 {
            let candidate = "\(baseName)-\(index)"
            if !existingNames.contains(candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: Provider plumbing

    private func ensureSupported() throws {
        guard providerKind == .oneDrive else {
            throw CloudVaultError.unsupportedProvider(kind)
        }
    }

    private func listItems() async throws -> [CloudFileItem] {
        do {
            return try await provider.listFiles()
        } catch {
            throw mapProviderError(error, notFound: .remoteManifestMissing)
        }
    }

    /// `CloudFileProviderError` is the provider's whole error vocabulary, so the
    /// mapping is intentionally coarse. `notFound` lets manifest operations report a
    /// missing manifest instead of a missing vault.
    private func mapProviderError(_ error: Error, notFound: CloudVaultError) -> CloudVaultError {
        if let error = error as? CloudVaultError {
            return error
        }
        guard let providerError = error as? CloudFileProviderError else {
            return CloudVaultError.network(error.localizedDescription)
        }
        switch providerError {
        case .authenticationRequired:
            return CloudVaultError.unauthorized(kind)
        case .itemNotFound:
            return notFound
        case .conflict:
            return CloudVaultError.preconditionFailed(remoteRevision: nil)
        case .unsupportedOperation, .invalidDirectoryName:
            // 目录名由设置界面校验；走到这里说明持久化数据异常，按供应商不支持处理。
            return CloudVaultError.unsupportedProvider(kind)
        case .notConfigured:
            // 缺少开发者门户配置（客户端 ID / URL scheme）时按未授权处理，
            // 设置界面会先把它显示为“未配置”并禁用入口。
            return CloudVaultError.unauthorized(kind)
        }
    }
}
