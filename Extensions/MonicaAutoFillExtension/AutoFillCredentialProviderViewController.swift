import AuthenticationServices
import MonicaCore
import MonicaSecurity
import MonicaStorage
import UIKit

final class AutoFillCredentialProviderViewController: ASCredentialProviderViewController, UISearchBarDelegate {
    private let appGroupIdentifier = "group.monica-pass.monica"
    private var loadTask: Task<Void, Never>?
    private var credentialResolver: AutoFillCredentialResolver?
    private var matchedCredentialRecords: [AutoFillCredentialIndexRecord] = []
    private let passkeyCredentialManager = MonicaPasskeyCredentialManager(
        privateKeyStore: KeychainPasskeyPrivateKeyStore()
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        configureLockedView()
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        loadMatchingCredentialIndexRecords(for: serviceIdentifiers)
    }

    override func prepareCredentialList(
        for serviceIdentifiers: [ASCredentialServiceIdentifier],
        requestParameters: ASPasskeyCredentialRequestParameters
    ) {
        configurePasskeyStatusView(
            relyingPartyID: requestParameters.relyingPartyIdentifier,
            status: "Passkey 认证需要在 Monica 中解锁并选择凭据"
        )
    }

    override func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) {
        if let recordIdentifier = credentialIdentity.recordIdentifier,
           let secret = try? credentialResolver?.credential(recordIdentifier: recordIdentifier) {
            let credential = ASPasswordCredential(
                user: secret.username,
                password: secret.password
            )
            extensionContext.completeRequest(
                withSelectedCredential: credential,
                completionHandler: nil
            )
            return
        }

        cancelRequest(code: ASExtensionError.Code.userInteractionRequired)
    }

    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        if let passkeyRequest = credentialRequest as? ASPasskeyCredentialRequest {
            completePasskeyAssertion(for: passkeyRequest)
            return
        }

        cancelRequest(code: ASExtensionError.Code.userInteractionRequired)
    }

    override func prepareInterfaceToProvideCredential(for credentialIdentity: ASPasswordCredentialIdentity) {
        loadMatchingCredentialIndexRecords(
            for: [credentialIdentity.serviceIdentifier],
            preferredRecordIdentifier: credentialIdentity.recordIdentifier
        )
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        if let passkeyRequest = credentialRequest as? ASPasskeyCredentialRequest {
            completePasskeyAssertion(for: passkeyRequest)
            return
        }

        configureStatusView(title: "Monica", status: "此凭据请求需要在 Monica 中完成")
    }

    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        if let passkeyRequest = registrationRequest as? ASPasskeyCredentialRequest {
            completePasskeyRegistration(for: passkeyRequest)
            return
        }

        configureStatusView(title: "Monica Passkey", status: "Passkey 注册请求已收到")
    }

    @available(iOS 26.2, *)
    override func performWithoutUserInteractionIfPossible(savePasswordRequest: ASSavePasswordRequest) {
        persistAutoFillSaveRequest(savePasswordRequest, allowsCompletion: true)
    }

    @available(iOS 26.2, *)
    override func prepareInterface(for savePasswordRequest: ASSavePasswordRequest) {
        persistAutoFillSaveRequest(savePasswordRequest, allowsCompletion: true)
    }

    deinit {
        loadTask?.cancel()
    }

    private func configureLockedView() {
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Monica"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true

        let statusLabel = UILabel()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "保险库已锁定"
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .secondaryLabel
        statusLabel.adjustsFontForContentSizeCategory = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8

        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor)
        ])
    }

    private func loadMatchingCredentialIndexRecords(
        for serviceIdentifiers: [ASCredentialServiceIdentifier],
        preferredRecordIdentifier: String? = nil
    ) {
        configureStatusView(title: "Monica", status: "正在解锁自动填充")
        loadTask?.cancel()
        loadTask = Task { [appGroupIdentifier] in
            do {
                let unlockedData = try await Self.loadUnlockedCredentialData(
                    appGroupIdentifier: appGroupIdentifier
                )
                let resolver = AutoFillCredentialResolver(
                    index: unlockedData.index,
                    secrets: unlockedData.secrets
                )
                let records = resolver.records(
                    matchingServiceIdentifiers: serviceIdentifiers.map(\.identifier)
                )
                await MainActor.run {
                    self.credentialResolver = resolver
                    self.matchedCredentialRecords = records
                    if let preferredRecordIdentifier,
                       let secret = try? resolver.credential(
                        recordIdentifier: preferredRecordIdentifier
                       ) {
                        let credential = ASPasswordCredential(
                            user: secret.username,
                            password: secret.password
                        )
                        self.extensionContext.completeRequest(
                            withSelectedCredential: credential,
                            completionHandler: nil
                        )
                        return
                    }
                    self.configureCredentialList(records, searchQuery: "")
                }
            } catch {
                await MainActor.run {
                    self.credentialResolver = nil
                    self.matchedCredentialRecords = []
                    self.configureStatusView(
                        title: "Monica",
                        status: error.localizedDescription
                    )
                }
            }
        }
    }

    private static func loadUnlockedCredentialData(
        appGroupIdentifier: String
    ) async throws -> AutoFillUnlockedCredentialData {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw AutoFillExtensionError.appGroupUnavailable
        }

        let encryptedIndexStore = FileAutoFillEncryptedIndexStore(
            appGroupContainerURL: containerURL
        )
        guard let encryptedIndex = try encryptedIndexStore.load() else {
            throw AutoFillExtensionError.indexUnavailable
        }
        let credentialSecretStore = FileAutoFillCredentialSecretStore(
            appGroupContainerURL: containerURL
        )
        guard let encryptedSecrets = try credentialSecretStore.load() else {
            throw AutoFillExtensionError.credentialSecretsUnavailable
        }

        let keychainManager = AutoFillIndexKeychainManager(
            store: KeychainAutoFillIndexKeyStore(),
            authenticator: DeviceOwnerLocalAuthenticator()
        )
        let keyMaterial = try await keychainManager.loadKeyMaterialAfterAuthentication(
            vaultID: encryptedIndex.vaultID,
            reason: "解锁 Monica 自动填充"
        )
        let key = try AutoFillIndexEncryptionKey(rawValue: keyMaterial.keyMaterial)
        let unlockedIndex = try AutoFillCredentialIndexUnlocker().unlock(
            encryptedIndex,
            vaultID: encryptedIndex.vaultID,
            keyIdentifier: keyMaterial.keyIdentifier,
            key: key
        )
        let unlockedSecrets = try AutoFillCredentialSecretUnlocker().unlock(
            encryptedSecrets,
            vaultID: encryptedIndex.vaultID,
            keyIdentifier: keyMaterial.keyIdentifier,
            key: key
        )
        return AutoFillUnlockedCredentialData(
            index: unlockedIndex,
            secrets: unlockedSecrets
        )
    }

    private func configureStatusView(title: String, status: String) {
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true

        let statusLabel = UILabel()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = status
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.adjustsFontForContentSizeCategory = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8

        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor)
        ])
    }

    private func configurePasskeyStatusView(relyingPartyID: String, status: String) {
        let sanitizedRelyingPartyID = relyingPartyID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = sanitizedRelyingPartyID.isEmpty
            ? "Monica Passkey"
            : "Monica Passkey · \(sanitizedRelyingPartyID)"
        configureStatusView(title: title, status: status)
    }

    private func relyingPartyID(for request: ASPasskeyCredentialRequest) -> String {
        guard let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity else {
            return ""
        }
        return identity.relyingPartyIdentifier
    }

    private func passkeyIdentity(for request: ASPasskeyCredentialRequest) throws -> ASPasskeyCredentialIdentity {
        guard let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity else {
            throw AutoFillExtensionError.passkeyIdentityUnavailable
        }
        return identity
    }

    private func completePasskeyRegistration(for request: ASPasskeyCredentialRequest) {
        do {
            let identity = try passkeyIdentity(for: request)
            let registration = try passkeyCredentialManager.createRegistration(
                relyingPartyID: identity.relyingPartyIdentifier,
                username: identity.userName,
                userHandle: identity.userHandle,
                clientDataHash: request.clientDataHash
            )
            let credential = ASPasskeyRegistrationCredential(
                relyingParty: registration.relyingPartyID,
                clientDataHash: request.clientDataHash,
                credentialID: registration.credentialID,
                attestationObject: registration.attestationObject
            )
            try persistPasskeyRegistration(registration)
            savePasskeyIdentity(for: registration)
            extensionContext.completeRegistrationRequest(
                using: credential,
                completionHandler: nil
            )
        } catch {
            configurePasskeyStatusView(
                relyingPartyID: relyingPartyID(for: request),
                status: "Passkey 注册失败，请回到 Monica 检查凭据状态"
            )
            cancelRequest(code: ASExtensionError.Code.failed)
        }
    }

    private func completePasskeyAssertion(for request: ASPasskeyCredentialRequest) {
        do {
            let identity = try passkeyIdentity(for: request)
            let assertion = try passkeyCredentialManager.createAssertion(
                relyingPartyID: identity.relyingPartyIdentifier,
                credentialID: identity.credentialID,
                userHandle: identity.userHandle,
                clientDataHash: request.clientDataHash
            )
            let credential = ASPasskeyAssertionCredential(
                userHandle: assertion.userHandle,
                relyingParty: assertion.relyingPartyID,
                signature: assertion.signature,
                clientDataHash: assertion.clientDataHash,
                authenticatorData: assertion.authenticatorData,
                credentialID: assertion.credentialID
            )
            extensionContext.completeAssertionRequest(
                using: credential,
                completionHandler: nil
            )
        } catch {
            configurePasskeyStatusView(
                relyingPartyID: relyingPartyID(for: request),
                status: "Passkey 认证失败，请回到 Monica 检查凭据状态"
            )
            cancelRequest(code: ASExtensionError.Code.credentialIdentityNotFound)
        }
    }

    private func savePasskeyIdentity(for registration: MonicaPasskeyRegistrationResult) {
        let identity = ASPasskeyCredentialIdentity(
            relyingPartyIdentifier: registration.relyingPartyID,
            userName: registration.username,
            credentialID: registration.credentialID,
            userHandle: registration.userHandle,
            recordIdentifier: registration.privateKeyReference
        )
        ASCredentialIdentityStore.shared.saveCredentialIdentities([identity]) { _, _ in
            // Best-effort system discovery; the private key is already persisted in Keychain.
        }
    }

    private func persistPasskeyRegistration(_ registration: MonicaPasskeyRegistrationResult) throws {
        guard let inboxStore = AppSystemPasskeyRegistrationInboxStore(
            appGroupIdentifier: appGroupIdentifier
        ) else {
            throw AutoFillExtensionError.appGroupUnavailable
        }
        let title = registration.relyingPartyID.trimmingCharacters(in: .whitespacesAndNewlines)
        try inboxStore.saveIncomingRegistration(
            AppSystemPasskeyRegistrationInboxItem(
                relyingPartyID: registration.relyingPartyID,
                username: registration.username,
                userHandle: registration.userHandle,
                credentialID: registration.credentialID,
                publicKeyCOSE: registration.publicKeyCOSE,
                privateKeyReference: registration.privateKeyReference,
                title: title.isEmpty ? registration.username : title
            )
        )
    }

    @available(iOS 26.2, *)
    private func persistAutoFillSaveRequest(
        _ savePasswordRequest: ASSavePasswordRequest,
        allowsCompletion: Bool
    ) {
        do {
            guard let inboxStore = AppAutoFillCredentialSaveInboxStore(
                appGroupIdentifier: appGroupIdentifier
            ) else {
                throw AutoFillExtensionError.appGroupUnavailable
            }
            let request = AppAutoFillCredentialSaveRequest(
                serviceIdentifier: savePasswordRequest.serviceIdentifier.identifier,
                username: savePasswordRequest.credential.user,
                password: savePasswordRequest.credential.password,
                title: savePasswordRequest.title ?? ""
            )
            try inboxStore.saveIncomingRequest(request)
            configureStatusView(
                title: "Monica",
                status: "自动填充保存请求已交给 Monica"
            )
            if allowsCompletion {
                extensionContext.completeSavePasswordRequest(completionHandler: nil)
            }
        } catch {
            configureStatusView(
                title: "Monica",
                status: "自动填充保存失败，请稍后在 Monica 中重试"
            )
            cancelRequest(code: ASExtensionError.Code.failed)
        }
    }

    private func configureCredentialList(
        _ records: [AutoFillCredentialIndexRecord],
        searchQuery: String
    ) {
        guard !records.isEmpty || !searchQuery.isEmpty else {
            configureStatusView(title: "Monica", status: "没有匹配的凭据")
            return
        }

        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Monica"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true

        let searchBar = UISearchBar()
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.placeholder = "搜索"
        searchBar.searchTextField.text = searchQuery
        searchBar.delegate = self

        let stack = UIStackView(arrangedSubviews: [titleLabel, searchBar])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12

        if records.isEmpty {
            let emptyLabel = UILabel()
            emptyLabel.text = "无结果"
            emptyLabel.font = .preferredFont(forTextStyle: .body)
            emptyLabel.textColor = .secondaryLabel
            emptyLabel.textAlignment = .center
            emptyLabel.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(emptyLabel)
        }

        for record in records {
            var configuration = UIButton.Configuration.plain()
            configuration.title = record.title
            configuration.subtitle = record.username
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .preferredFont(forTextStyle: .headline)
                return attributes
            }
            configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .preferredFont(forTextStyle: .subheadline)
                attributes.foregroundColor = .secondaryLabel
                return attributes
            }
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: 8,
                leading: 0,
                bottom: 8,
                trailing: 0
            )
            let button = UIButton(configuration: configuration)
            button.contentHorizontalAlignment = .leading
            button.addAction(
                UIAction { [weak self] _ in
                    self?.completeCredentialSelection(record)
                },
                for: .touchUpInside
            )
            stack.addArrangedSubview(button)
        }

        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        guard let credentialResolver else {
            return
        }

        let filteredRecords = credentialResolver.search(
            searchText,
            within: matchedCredentialRecords
        )
        configureCredentialList(filteredRecords, searchQuery: searchText)
    }

    private func completeCredentialSelection(_ record: AutoFillCredentialIndexRecord) {
        do {
            let secret = try credentialResolver?.credential(for: record)
            guard let secret else {
                throw AutoFillExtensionError.credentialSecretUnavailable
            }
            let credential = ASPasswordCredential(
                user: secret.username,
                password: secret.password
            )
            extensionContext.completeRequest(
                withSelectedCredential: credential,
                completionHandler: nil
            )
        } catch {
            configureStatusView(title: "Monica", status: error.localizedDescription)
            return
        }
    }

    private func cancelRequest(code: ASExtensionError.Code) {
        let error = NSError(domain: ASExtensionErrorDomain, code: code.rawValue)
        extensionContext.cancelRequest(withError: error)
    }
}

private struct AutoFillUnlockedCredentialData {
    let index: AutoFillUnlockedCredentialIndex
    let secrets: AutoFillUnlockedCredentialSecretSnapshot
}

private enum AutoFillExtensionError: Error, LocalizedError {
    case appGroupUnavailable
    case indexUnavailable
    case credentialSecretsUnavailable
    case credentialSecretUnavailable
    case passkeyIdentityUnavailable

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "无法访问共享数据，请重新打开 Monica 后再试。"
        case .indexUnavailable:
            return "自动填充索引不可用。"
        case .credentialSecretsUnavailable:
            return "自动填充凭据密钥不可用。"
        case .credentialSecretUnavailable:
            return "自动填充凭据密钥不可用。"
        case .passkeyIdentityUnavailable:
            return "Passkey 身份不可用。"
        }
    }
}
