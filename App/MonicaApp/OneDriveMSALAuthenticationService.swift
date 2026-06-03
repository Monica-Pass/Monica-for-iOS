import Foundation
import MonicaSync
import MSAL
import UIKit

final class DefaultAppOneDriveMSALAuthenticationService: AppOneDriveAuthenticationService, @unchecked Sendable {
    private let configuration: OneDriveCloudFileConfiguration
    private let userDefaults: UserDefaults
    private let accountIdentifierKey: String

    init(
        configuration: OneDriveCloudFileConfiguration = .monicaProduction,
        userDefaults: UserDefaults = .standard,
        accountIdentifierKey: String = "Monica.OneDrive.MSAL.CurrentAccountIdentifier"
    ) {
        self.configuration = configuration
        self.userDefaults = userDefaults
        self.accountIdentifierKey = accountIdentifierKey
    }

    func accessToken() async throws -> String {
        let application = try makeApplication()
        guard let account = try currentAccount(application: application) else {
            throw CloudFileProviderError.authenticationRequired(provider: .oneDrive)
        }

        let parameters = MSALSilentTokenParameters(scopes: configuration.scopes, account: account)
        let result = try await acquireTokenSilent(application: application, parameters: parameters)
        guard !result.accessToken.isEmpty else {
            throw AppOneDriveAuthenticationError.tokenUnavailable
        }
        return result.accessToken
    }

    func signIn() async throws -> AppOneDriveAuthenticationSession {
        let presenter = try await MainActor.run {
            guard let viewController = Self.currentPresentationViewController() else {
                throw AppOneDriveAuthenticationError.presentationUnavailable
            }
            return viewController
        }
        let application = try makeApplication()
        let webParameters = MSALWebviewParameters(authPresentationViewController: presenter)
        let parameters = MSALInteractiveTokenParameters(scopes: configuration.scopes, webviewParameters: webParameters)
        parameters.promptType = .selectAccount

        let result = try await acquireToken(application: application, parameters: parameters)
        let account = result.account
        guard let accountIdentifier = account.homeAccountId?.identifier ?? account.identifier else {
            throw AppOneDriveAuthenticationError.tokenUnavailable
        }
        saveAccountIdentifier(accountIdentifier)
        return AppOneDriveAuthenticationSession(accountLabel: redactedAccountLabel(for: account))
    }

    func signOut() async throws {
        let application = try makeApplication()
        if let account = try currentAccount(application: application) {
            try application.remove(account)
        } else {
            let accounts = try application.allAccounts()
            for account in accounts {
                try application.remove(account)
            }
        }
        clearAccountIdentifier()
    }

    func handleRedirectURL(_ url: URL) -> Bool {
        guard url.scheme == configuration.redirectScheme else {
            return false
        }
        return MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: nil)
    }

    private func makeApplication() throws -> MSALPublicClientApplication {
        let config = MSALPublicClientApplicationConfig(
            clientId: configuration.clientID,
            redirectUri: configuration.redirectURI.absoluteString,
            authority: nil
        )
        return try MSALPublicClientApplication(configuration: config)
    }

    private func acquireToken(
        application: MSALPublicClientApplication,
        parameters: MSALInteractiveTokenParameters
    ) async throws -> MSALResult {
        try await withCheckedThrowingContinuation { continuation in
            application.acquireToken(with: parameters) { result, error in
                Self.resume(continuation, result: result, error: error)
            }
        }
    }

    private func acquireTokenSilent(
        application: MSALPublicClientApplication,
        parameters: MSALSilentTokenParameters
    ) async throws -> MSALResult {
        try await withCheckedThrowingContinuation { continuation in
            application.acquireTokenSilent(with: parameters) { result, error in
                Self.resume(continuation, result: result, error: error)
            }
        }
    }

    private static func resume(
        _ continuation: CheckedContinuation<MSALResult, Error>,
        result: MSALResult?,
        error: Error?
    ) {
        if let error {
            let nsError = error as NSError
            if nsError.domain == MSALErrorDomain,
               nsError.code == MSALError.userCanceled.rawValue {
                continuation.resume(throwing: AppOneDriveAuthenticationError.authenticationCancelled)
            } else {
                continuation.resume(throwing: AppOneDriveAuthenticationError.authenticationFailed(
                    domain: nsError.domain,
                    code: nsError.code,
                    message: diagnosticMessage(for: nsError)
                ))
            }
            return
        }
        guard let result else {
            continuation.resume(throwing: AppOneDriveAuthenticationError.tokenUnavailable)
            return
        }
        continuation.resume(returning: result)
    }

    static func diagnosticMessage(for error: NSError) -> String {
        var parts = [error.localizedDescription]
        let fields: [(label: String, key: String)] = [
            ("MSALInternalErrorCodeKey", MSALInternalErrorCodeKey),
            ("MSALOAuthErrorKey", MSALOAuthErrorKey),
            ("MSALOAuthSubErrorKey", MSALOAuthSubErrorKey),
            ("MSALOAuthSubErrorDescriptionKey", MSALOAuthSubErrorDescriptionKey),
            ("MSALErrorDescriptionKey", MSALErrorDescriptionKey),
            ("MSALSTSErrorCodesKey", MSALSTSErrorCodesKey),
            ("MSALCorrelationIDKey", MSALCorrelationIDKey),
            ("MSALHTTPResponseCodeKey", MSALHTTPResponseCodeKey)
        ]
        for field in fields {
            guard let value = error.userInfo[field.key] else {
                continue
            }
            let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, !parts.contains(text) {
                parts.append("\(field.label)=\(text)")
            }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=\(diagnosticMessage(for: underlying))")
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func currentAccount(application: MSALPublicClientApplication) throws -> MSALAccount? {
        guard let accountIdentifier = userDefaults.string(forKey: accountIdentifierKey),
              !accountIdentifier.isEmpty
        else {
            return nil
        }
        do {
            return try application.account(forIdentifier: accountIdentifier)
        } catch {
            clearAccountIdentifier()
            throw error
        }
    }

    private func saveAccountIdentifier(_ identifier: String) {
        userDefaults.set(identifier, forKey: accountIdentifierKey)
    }

    private func clearAccountIdentifier() {
        userDefaults.removeObject(forKey: accountIdentifierKey)
    }

    private func redactedAccountLabel(for account: MSALAccount) -> String {
        let username = account.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return username.isEmpty ? "已登录" : username
    }

    @MainActor
    private static func currentPresentationViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        return topViewController(from: root)
    }

    @MainActor
    private static func topViewController(from root: UIViewController?) -> UIViewController? {
        if let navigationController = root as? UINavigationController {
            return topViewController(from: navigationController.visibleViewController)
        }
        if let tabController = root as? UITabBarController {
            return topViewController(from: tabController.selectedViewController)
        }
        if let presented = root?.presentedViewController {
            return topViewController(from: presented)
        }
        return root
    }
}
