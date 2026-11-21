//
//  AppGoogleDriveAuthenticationService.swift
//  Monica
//
//  Google Drive OAuth 2.0 PKCE 登录态：ASWebAuthenticationSession 授权 + Keychain token 存储。
//

import AuthenticationServices
import Foundation
import MonicaSync
import UIKit

enum AppGoogleDriveConnectionState: Sendable, Equatable {
    case disconnected
    case running
    case connected(accountLabel: String)
    case failed(String)

    var label: String {
        switch self {
        case .disconnected:
            return String(localized: "Google Drive 未登录")
        case .running:
            return String(localized: "正在登录 Google Drive")
        case .connected(let accountLabel):
            let normalized = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty
                ? String(localized: "Google Drive 已登录")
                : String(localized: "Google Drive 已登录 \(normalized)")
        case .failed(let message):
            return message
        }
    }

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

struct AppGoogleDriveAuthenticationSession: Sendable, Equatable {
    let accountLabel: String

    var redactedSummary: String {
        let normalized = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Google Drive \(normalized.isEmpty ? String(localized: "已登录") : normalized)"
    }
}

protocol AppGoogleDriveAuthenticationService: GoogleDriveAccessTokenProvider {
    func restoreSession() async -> AppGoogleDriveAuthenticationSession?
    func signIn() async throws -> AppGoogleDriveAuthenticationSession
    func signOut() async
}

/// Google Drive 没有 drive.file 之外的资料权限，拿不到邮箱；统一用固定标签，避免把 token 派生信息写进界面。
private enum AppGoogleDriveAccountLabel {
    static let authorized = String(localized: "已授权")
}

@MainActor
final class AppGoogleDriveAuthorizationPresenter: NSObject, GoogleDriveAuthorizationPresenting {
    private var authenticationSession: ASWebAuthenticationSession?

    // 允许在非隔离的默认参数里构造；真正的授权调用仍然回到主线程。
    nonisolated override init() {
        super.init()
    }

    func presentAuthorization(url: URL, callbackURLScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme
            ) { callbackURL, error in
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
                       nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: GoogleDriveAuthError.authorizationCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: GoogleDriveAuthError.invalidCallback)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            // 不共享 Safari 的 cookie：Google 账号选择每次都走显式登录，退出后不会残留会话。
            session.prefersEphemeralWebBrowserSession = true
            self.authenticationSession = session
            guard session.start() else {
                self.authenticationSession = nil
                continuation.resume(throwing: GoogleDriveAuthError.invalidAuthorizationURL)
                return
            }
        }
    }

    /// Google 的授权页在系统浏览器里完成后必须回到 App，这里只负责给出承载窗口。
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            AppGoogleDriveAuthorizationPresenter.activeWindow() ?? ASPresentationAnchor()
        }
    }

    private static func activeWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow)
            ?? windows.first(where: { !$0.isHidden })
    }
}

extension AppGoogleDriveAuthorizationPresenter: ASWebAuthenticationPresentationContextProviding {}

final class DefaultAppGoogleDriveAuthenticationService: AppGoogleDriveAuthenticationService, @unchecked Sendable {
    private let configuration: GoogleDriveConfiguration
    private let oauthService: GoogleDriveOAuthService
    private let presenter: AppGoogleDriveAuthorizationPresenter

    init(
        configuration: GoogleDriveConfiguration,
        tokenStore: any GoogleDriveTokenStore = KeychainGoogleDriveTokenStore(),
        transport: any GoogleDriveHTTPTransport = URLSessionGoogleDriveHTTPTransport(),
        presenter: AppGoogleDriveAuthorizationPresenter = AppGoogleDriveAuthorizationPresenter(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.presenter = presenter
        self.oauthService = GoogleDriveOAuthService(
            configuration: configuration,
            tokenStore: tokenStore,
            transport: transport,
            presenter: presenter,
            now: now
        )
    }

    func accessToken() async throws -> String {
        try await oauthService.accessToken()
    }

    func refreshAccessToken() async throws -> String {
        try await oauthService.refreshAccessToken()
    }

    func restoreSession() async -> AppGoogleDriveAuthenticationSession? {
        guard configuration.isConfigured else {
            return nil
        }
        do {
            _ = try await oauthService.accessToken()
            return AppGoogleDriveAuthenticationSession(accountLabel: AppGoogleDriveAccountLabel.authorized)
        } catch {
            return nil
        }
    }

    func signIn() async throws -> AppGoogleDriveAuthenticationSession {
        _ = try await oauthService.signIn()
        return AppGoogleDriveAuthenticationSession(accountLabel: AppGoogleDriveAccountLabel.authorized)
    }

    func signOut() async {
        try? await oauthService.signOut()
    }
}
