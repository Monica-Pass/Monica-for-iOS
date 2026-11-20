//
//  AppSessionModel+CloudVaultSync.swift
//  Monica
//
//  会话模型的云端保险库同步（issue #31）。
//

import MonicaStorage
import MonicaSync
import Foundation
import UIKit

extension AppSessionModel {
    /// Builds the main-actor bridge used by the 云端保险库 settings screen.
    ///
    /// The bridge deliberately reads the active vault file through the open
    /// session's descriptor: the file is already encrypted by MDBX, so the
    /// cloud sync never needs the master password for ordinary uploads and
    /// downloads.
    @MainActor
    func makeCloudVaultSyncBridge() throws -> AppCloudVaultSyncBridge {
        guard vaultState == .unlocked else {
            throw AppCloudVaultSyncError.vaultLocked
        }
        guard let unlockedSession = activeVaultSession,
              activeEntryRepository != nil else {
            throw AppCloudVaultSyncError.vaultUnavailable
        }

        let fileURL = unlockedSession.descriptor.fileURL
        let vaultDirectoryURL = fileURL.deletingLastPathComponent()
        let vaultFileName = fileURL.lastPathComponent
        let vaultID = unlockedSession.handle.vaultID
        let vaultName = unlockedSession.descriptor.displayName
        let deviceID = unlockedSession.handle.deviceID
        let deviceName = UIDevice.current.name
        let stateFileURL = vaultDirectoryURL.appendingPathComponent(
            CloudVaultProtocolSpec.syncStateFileName,
            isDirectory: false
        )

        let webDAVEndpoint = try? makeWebDAVEndpoint()
        let oneDriveProvider = try? cloudFileProvider(for: .oneDrive)
        var availableProviders: [CloudVaultRemoteKind] = []
        if webDAVEndpoint != nil {
            availableProviders.append(.webDAV)
        }
        if oneDriveProvider != nil {
            availableProviders.append(.oneDrive)
        }

        return AppCloudVaultSyncBridge(
            vaultID: vaultID,
            vaultName: vaultName,
            vaultFileName: vaultFileName,
            deviceID: deviceID,
            deviceName: deviceName,
            stateFileURL: stateFileURL,
            availableProviders: availableProviders,
            makeStore: { kind in
                switch kind {
                case .webDAV:
                    guard let webDAVEndpoint else {
                        throw CloudVaultError.notConfigured(reason: "WebDAV 服务器地址、账号或密码尚未配置")
                    }
                    return WebDAVCloudVaultRemoteStore(
                        endpoint: webDAVEndpoint,
                        vaultFileName: vaultFileName
                    )
                case .oneDrive:
                    guard let oneDriveProvider else {
                        throw CloudVaultError.notConfigured(reason: "尚未登录 OneDrive")
                    }
                    return CloudFileCloudVaultRemoteStore(
                        provider: oneDriveProvider,
                        vaultFileName: vaultFileName
                    )
                }
            },
            localSnapshot: {
                let data: Data
                do {
                    data = try Data(contentsOf: fileURL)
                } catch {
                    throw CloudVaultError.invalidLocalVault(
                        reason: "无法读取保险库文件：\(error.localizedDescription)"
                    )
                }
                return try CloudVaultLocalSnapshot.make(
                    vaultID: vaultID,
                    vaultName: vaultName,
                    data: data,
                    deviceID: deviceID,
                    deviceName: deviceName
                )
            },
            applySameVault: { outcome in
                self.lockLocalVault()
                do {
                    try FileManager.default.createDirectory(
                        at: vaultDirectoryURL,
                        withIntermediateDirectories: true
                    )
                    try outcome.vaultData.write(to: fileURL, options: .atomic)
                } catch {
                    throw AppCloudVaultSyncError.applyFailed(
                        "写回本机保险库失败：\(error.localizedDescription)"
                    )
                }
            },
            adoptDifferentVault: { outcome, password in
                try self.adoptDownloadedCloudVault(
                    outcome,
                    password: password,
                    vaultDirectoryURL: vaultDirectoryURL,
                    deviceID: deviceID
                )
            },
            providerHost: { kind in
                // Only the WebDAV endpoint is a URL the app owns; OneDrive hosts
                // are Graph endpoints, not the user's server.
                kind == .webDAV ? webDAVEndpoint?.baseURL : nil
            }
        )
    }

    /// Validates a vault downloaded from another device with its own password and
    /// saves it as a *new* local vault file. The currently open vault is never
    /// touched, so a wrong password or a mismatched vault cannot destroy data.
    @MainActor
    private func adoptDownloadedCloudVault(
        _ outcome: CloudVaultPullOutcome,
        password: String,
        vaultDirectoryURL: URL,
        deviceID: String
    ) throws -> URL {
        let manifest = outcome.remote.manifest
        let temporaryURL = vaultDirectoryURL.appendingPathComponent(
            ".cloud-vault-\(UUID().uuidString).mdbx",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            try outcome.vaultData.write(to: temporaryURL, options: .atomic)
            let validator = LocalVaultRepository()
            let session = try validator.openVault(
                at: temporaryURL,
                password: password,
                deviceID: deviceID
            )
            defer { validator.closeVault(for: session) }
            guard session.handle.vaultID == manifest.vaultID else {
                throw CloudVaultError.vaultIDMismatch(
                    expectedVaultID: manifest.vaultID,
                    actualVaultID: session.handle.vaultID
                )
            }
            _ = try validator.entryRepository(for: session).listProjects()
        } catch let error as CloudVaultError {
            throw error
        } catch {
            throw AppCloudVaultSyncError.applyFailed(
                "密码不正确，或云端保险库文件无法打开：\(error.localizedDescription)"
            )
        }

        let baseName = CloudVaultNaming.sanitizedFileName(manifest.vaultName)
        var destinationURL = vaultDirectoryURL.appendingPathComponent(
            "\(baseName).mdbx",
            isDirectory: false
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let stamp = CloudVaultNaming.timestampString(Date())
            destinationURL = vaultDirectoryURL.appendingPathComponent(
                "\(baseName)-\(stamp).mdbx",
                isDirectory: false
            )
        }
        try outcome.vaultData.write(to: destinationURL, options: .atomic)
        return destinationURL
    }
}
