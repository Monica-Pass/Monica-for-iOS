import AuthenticationServices
import LocalAuthentication
import MonicaCore
import MonicaSecurity
import MonicaStorage
import UIKit

final class AutoFillCredentialProviderViewController: ASCredentialProviderViewController, UISearchBarDelegate {
    private let appGroupIdentifier = "group.com.monicapass.monica"
    private var loadTask: Task<Void, Never>?
    private var passkeyListTask: Task<Void, Never>?
    private var credentialResolver: AutoFillCredentialResolver?
    private var matchedCredentialRecords: [AutoFillCredentialIndexRecord] = []
    private let passkeyCredentialManager = MonicaPasskeyCredentialManager(
        privateKeyStore: KeychainPasskeyPrivateKeyStore()
    )

    private var hasAppeared = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureLockedView()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        loadMatchingCredentialIndexRecords(for: serviceIdentifiers)
    }

    override func prepareCredentialList(
        for serviceIdentifiers: [ASCredentialServiceIdentifier],
        requestParameters: ASPasskeyCredentialRequestParameters
    ) {
        loadPasskeyIdentities(
            for: requestParameters,
            fallbackServiceIdentifiers: serviceIdentifiers
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
            // Passkey assertions must never be signed silently: the extension has to verify
            // the device owner (UV) first, so hand the request back to the system UI.
            configurePasskeyStatusView(
                relyingPartyID: relyingPartyID(for: passkeyRequest),
                status: "需要验证设备所有者后才能使用通行密钥"
            )
            cancelRequest(code: ASExtensionError.Code.userInteractionRequired)
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
            do {
                let identity = try passkeyIdentity(for: passkeyRequest)
                authenticateAndCompletePasskeyAssertion(
                    identity: identity,
                    clientDataHash: passkeyRequest.clientDataHash
                )
            } catch {
                configurePasskeyStatusView(
                    relyingPartyID: relyingPartyID(for: passkeyRequest),
                    status: "Passkey 身份不可用，请回到 Monica 检查凭据状态"
                )
                cancelRequest(code: ASExtensionError.Code.credentialIdentityNotFound)
            }
            return
        }

        configureStatusView(title: "Monica", status: "此凭据请求需要在 Monica 中完成")
    }

    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        guard let passkeyRequest = registrationRequest as? ASPasskeyCredentialRequest else {
            configureStatusView(title: "Monica Passkey", status: "Passkey 注册请求已收到")
            return
        }

        let relyingPartyID = relyingPartyID(for: passkeyRequest)
        guard passkeyRequest.supportedAlgorithms.contains(.ES256) else {
            Self.logPasskeyDiagnostic(
                "registration rejected algorithms=\(passkeyRequest.supportedAlgorithms.map(\.rawValue))"
            )
            configurePasskeyStatusView(
                relyingPartyID: relyingPartyID,
                status: "此站点要求的签名算法不受支持"
            )
            cancelRequest(code: ASExtensionError.Code.failed)
            return
        }

        // Every open-source provider (KeePassium, Keyguard, Bitwarden, AliasVault) completes a
        // registration only after an explicit tap in its own UI. Completing from the system
        // callback makes Safari/WebKit treat the ceremony as unconfirmed.
        configurePasskeyRegistrationView(
            relyingPartyID: relyingPartyID,
            username: (passkeyRequest.credentialIdentity as? ASPasskeyCredentialIdentity)?.userName ?? "",
            onConfirm: { [weak self] in
                self?.beginPasskeyRegistration(passkeyRequest, relyingPartyID: relyingPartyID)
            }
        )
    }

    private func beginPasskeyRegistration(
        _ passkeyRequest: ASPasskeyCredentialRequest,
        relyingPartyID: String
    ) {
        configurePasskeyStatusView(
            relyingPartyID: relyingPartyID,
            status: "正在验证设备所有者"
        )
        Task { @MainActor [weak self] in
            let verification = await self?.verifyDeviceOwnerAfterAppearing(
                reason: "为 \(relyingPartyID) 创建 Monica 通行密钥"
            ) ?? .unavailable
            guard let self, verification != .cancelled else {
                Self.logPasskeyDiagnostic("registration aborted verification=\(verification)")
                self?.cancelRequest(code: ASExtensionError.Code.userCanceled)
                return
            }
            // A relying party that lists one of our credentials in excludedCredentials must
            // not receive a duplicate passkey for the same account.
            if await self.matchesExcludedCredential(passkeyRequest) {
                Self.logPasskeyDiagnostic("registration rejected excluded-credential")
                self.configurePasskeyStatusView(
                    relyingPartyID: relyingPartyID,
                    status: "此账号已有通行密钥，无需重复创建"
                )
                self.cancelRequest(code: ASExtensionError.Code.failed)
                return
            }
            // When the device cannot verify its owner (no passcode/biometrics) the
            // registration still succeeds, but the authenticator data must not claim UV.
            self.completePasskeyRegistration(
                for: passkeyRequest,
                userVerified: verification == .verified
            )
        }
    }

    private func configurePasskeyRegistrationView(
        relyingPartyID: String,
        username: String,
        onConfirm: @escaping () -> Void
    ) {
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.text = "Monica Passkey · \(relyingPartyID)"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center

        let detailLabel = UILabel()
        detailLabel.text = username.isEmpty
            ? "为此站点创建通行密钥"
            : "为 \(username) 创建通行密钥"
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textColor = .secondaryLabel
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .center

        var configuration = UIButton.Configuration.filled()
        configuration.title = "创建通行密钥"
        configuration.cornerStyle = .large
        configuration.buttonSize = .large
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { _ in onConfirm() }, for: .touchUpInside)

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addAction(
            UIAction { [weak self] _ in
                Self.logPasskeyDiagnostic("registration cancelled by user")
                self?.cancelRequest(code: ASExtensionError.Code.userCanceled)
            },
            for: .touchUpInside
        )

        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel, button, cancelButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 16

        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
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
        passkeyListTask?.cancel()
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
        preferredRecordIdentifier: String? = nil,
        emptyStatus: String? = nil
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
                    self.configureCredentialList(
                        records,
                        searchQuery: "",
                        emptyStatus: emptyStatus
                    )
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

    /// True when the relying party's `excludedCredentials` already covers one of our passkeys.
    private func matchesExcludedCredential(_ request: ASPasskeyCredentialRequest) async -> Bool {
        guard #available(iOS 18.0, *) else {
            return false
        }
        let excluded = Set((request.excludedCredentials ?? []).map(\.credentialID))
        guard !excluded.isEmpty else {
            return false
        }
        let identities = await ASCredentialIdentityStore.shared.credentialIdentities(
            forService: nil,
            credentialIdentityTypes: .passkey
        )
        return identities
            .compactMap { $0 as? ASPasskeyCredentialIdentity }
            .contains { excluded.contains($0.credentialID) }
    }

    private func completePasskeyRegistration(
        for request: ASPasskeyCredentialRequest,
        userVerified: Bool
    ) {
        do {
            let identity = try passkeyIdentity(for: request)
            let registration = try passkeyCredentialManager.createRegistration(
                relyingPartyID: identity.relyingPartyIdentifier,
                username: identity.userName,
                userHandle: identity.userHandle,
                clientDataHash: request.clientDataHash,
                userVerified: userVerified
            )
            let credential = ASPasskeyRegistrationCredential(
                relyingParty: registration.relyingPartyID,
                clientDataHash: request.clientDataHash,
                credentialID: registration.credentialID,
                attestationObject: registration.attestationObject
            )
            Self.logPasskeyDiagnostic(
                "registration cred=\(registration.credentialID.base64EncodedString()) "
                    + "rp=\(registration.relyingPartyID) user=\(registration.username) verified=\(userVerified)"
            )
            // Finish the ceremony before touching the credential identity store: mutating it
            // while the request is still in flight makes the platform abort the WebAuthn call.
            extensionContext.completeRegistrationRequest(using: credential) { [weak self] expired in
                Self.logPasskeyDiagnostic(
                    "registration-completed expired=\(expired) "
                        + "cred=\(registration.credentialID.base64EncodedString())"
                )
                guard let self, !expired else {
                    return
                }
                do {
                    try self.persistPasskeyRegistration(registration)
                } catch {
                    Self.logPasskeyDiagnostic("registration-inbox-failed error=\(error)")
                }
                self.savePasskeyIdentity(for: registration)
            }
        } catch {
            configurePasskeyStatusView(
                relyingPartyID: relyingPartyID(for: request),
                status: "Passkey 注册失败，请回到 Monica 检查凭据状态"
            )
            cancelRequest(code: ASExtensionError.Code.failed)
        }
    }

    /// Lists the passkeys that can satisfy an assertion request, then falls back to the
    /// password list when the extension holds no matching passkey identity.
    private func loadPasskeyIdentities(
        for requestParameters: ASPasskeyCredentialRequestParameters,
        fallbackServiceIdentifiers: [ASCredentialServiceIdentifier]
    ) {
        let relyingPartyID = requestParameters.relyingPartyIdentifier
        configurePasskeyStatusView(
            relyingPartyID: relyingPartyID,
            status: "正在读取通行密钥"
        )

        guard #available(iOS 17.4, *) else {
            loadMatchingCredentialIndexRecords(for: fallbackServiceIdentifiers)
            return
        }

        let allowedCredentialIDs = Set(requestParameters.allowedCredentials)
        let clientDataHash = requestParameters.clientDataHash
        passkeyListTask?.cancel()
        passkeyListTask = Task { @MainActor [weak self] in
            let identities = await ASCredentialIdentityStore.shared.credentialIdentities(
                forService: nil,
                credentialIdentityTypes: .passkey
            )
            guard let self, !Task.isCancelled else {
                return
            }

            let passkeyIdentities = identities.compactMap { $0 as? ASPasskeyCredentialIdentity }
            let relyingPartyMatches = passkeyIdentities.filter { identity in
                PasskeyRelyingPartyIDNormalizer.host(
                    identity.relyingPartyIdentifier,
                    isAllowedFor: relyingPartyID
                )
            }
            let allowedMatches = relyingPartyMatches.filter { identity in
                allowedCredentialIDs.isEmpty
                    || allowedCredentialIDs.contains(identity.credentialID)
            }
            // Like AliasVault: when the site's allow-list contains nothing we hold, still let
            // the user pick one of our passkeys for this relying party. Relying parties often
            // send stale or partial lists, and the site verifies the signature anyway.
            let candidates = allowedMatches.isEmpty ? relyingPartyMatches : allowedMatches
            let inventory = passkeyIdentities
                .map { "\($0.relyingPartyIdentifier)/\($0.credentialID.base64EncodedString())" }
                .joined(separator: ",")
            let allowList = allowedCredentialIDs.map { $0.base64EncodedString() }.joined(separator: ",")

            Self.logPasskeyDiagnostic(
                "identity-lookup store=\(identities.count) passkeys=\(passkeyIdentities.count) "
                    + "rpMatches=\(relyingPartyMatches.count) allowMatches=\(allowedMatches.count) "
                    + "candidates=\(candidates.count) rp=\(relyingPartyID) "
                    + "allow=[\(allowList)] have=[\(inventory)]"
            )
            guard !candidates.isEmpty else {
                let emptyStatus = passkeyIdentities.isEmpty
                    ? "Monica 中没有该站点的通行密钥，可改用密码或重新注册。"
                    : "此站点的通行密钥不在 Monica 中（可能保存在 iCloud 钥匙串），可改用密码或重新注册。"
                self.loadMatchingCredentialIndexRecords(
                    for: fallbackServiceIdentifiers,
                    emptyStatus: emptyStatus
                )
                return
            }

            let note = allowedMatches.isEmpty
                ? "网站请求的凭据不在 Monica 中，以下为该站点的其他通行密钥。"
                : nil
            self.configurePasskeyCredentialList(
                candidates,
                relyingPartyID: relyingPartyID,
                clientDataHash: clientDataHash,
                note: note
            )
        }
    }

    private func configurePasskeyCredentialList(
        _ identities: [ASPasskeyCredentialIdentity],
        relyingPartyID: String,
        clientDataHash: Data,
        note: String? = nil
    ) {
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Monica Passkey · \(relyingPartyID)"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12

        if let note {
            let noteLabel = UILabel()
            noteLabel.text = note
            noteLabel.font = .preferredFont(forTextStyle: .footnote)
            noteLabel.textColor = .secondaryLabel
            noteLabel.numberOfLines = 0
            noteLabel.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(noteLabel)
        }

        for identity in identities {
            var configuration = UIButton.Configuration.plain()
            configuration.title = identity.userName
            configuration.subtitle = identity.relyingPartyIdentifier
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
                    self?.authenticateAndCompletePasskeyAssertion(
                        identity: identity,
                        clientDataHash: clientDataHash
                    )
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

    /// Passkey assertions claim the UV flag, so the device owner must be verified first.
    private func authenticateAndCompletePasskeyAssertion(
        identity: ASPasskeyCredentialIdentity,
        clientDataHash: Data
    ) {
        let relyingPartyID = identity.relyingPartyIdentifier
        configurePasskeyStatusView(
            relyingPartyID: relyingPartyID,
            status: "正在验证设备所有者"
        )
        Task { @MainActor [weak self] in
            let verification = await self?.verifyDeviceOwnerAfterAppearing(
                reason: "使用 Monica 通行密钥登录 \(relyingPartyID)"
            ) ?? .unavailable
            guard let self, verification != .cancelled else {
                Self.logPasskeyDiagnostic("assertion aborted verification=\(verification)")
                self?.cancelRequest(code: ASExtensionError.Code.userInteractionRequired)
                return
            }
            self.completePasskeyAssertion(
                identity: identity,
                clientDataHash: clientDataHash,
                userVerified: verification == .verified
            )
        }
    }

    private func completePasskeyAssertion(
        identity: ASPasskeyCredentialIdentity,
        clientDataHash: Data,
        userVerified: Bool
    ) {
        do {
            let assertion = try passkeyCredentialManager.createAssertion(
                relyingPartyID: identity.relyingPartyIdentifier,
                credentialID: identity.credentialID,
                userHandle: identity.userHandle,
                clientDataHash: clientDataHash,
                userVerified: userVerified
            )
            let credential = ASPasskeyAssertionCredential(
                userHandle: assertion.userHandle,
                relyingParty: assertion.relyingPartyID,
                signature: assertion.signature,
                clientDataHash: assertion.clientDataHash,
                authenticatorData: assertion.authenticatorData,
                credentialID: assertion.credentialID
            )
            Self.logPasskeyDiagnostic(
                "assertion cred=\(assertion.credentialID.base64EncodedString()) "
                    + "rp=\(assertion.relyingPartyID) verified=\(userVerified) flags=\(assertion.authenticatorData[32])"
            )
            extensionContext.completeAssertionRequest(
                using: credential,
                completionHandler: nil
            )
        } catch {
            Self.logPasskeyDiagnostic(
                "assertion-failed cred=\(identity.credentialID.base64EncodedString()) "
                    + "rp=\(identity.relyingPartyIdentifier) error=\(error)"
            )
            configurePasskeyStatusView(
                relyingPartyID: identity.relyingPartyIdentifier,
                status: "Passkey 认证失败，请回到 Monica 检查凭据状态"
            )
            cancelRequest(code: ASExtensionError.Code.credentialIdentityNotFound)
        }
    }

    /// Publishing a single credential is enough here: the authoritative full sync belongs to
    /// the vault app, and a full `replaceCredentialIdentities` while a WebAuthn request is in
    /// flight can make the platform abort the ceremony.
    private func savePasskeyIdentity(for registration: MonicaPasskeyRegistrationResult) {
        let identity = ASPasskeyCredentialIdentity(
            relyingPartyIdentifier: registration.relyingPartyID,
            userName: registration.username,
            credentialID: registration.credentialID,
            userHandle: registration.userHandle,
            recordIdentifier: registration.privateKeyReference
        )
        let identities: [any ASCredentialIdentity] = [identity]

        ASCredentialIdentityStore.shared.getState { state in
            guard state.isEnabled else {
                Self.logPasskeyDiagnostic("identity-skip store-disabled")
                return
            }
            ASCredentialIdentityStore.shared.saveCredentialIdentities(identities) { success, error in
                Self.logPasskeyDiagnostic(
                    "identity-save success=\(success) incremental=\(state.supportsIncrementalUpdates) "
                        + "cred=\(registration.credentialID.base64EncodedString()) "
                        + "error=\(error.map { "\($0)" } ?? "nil")"
                )
            }
        }
    }

    /// Writes a one-line trace into the extension container so device runs can be inspected
    /// over USB (`afcclient --container com.monicapass.monica.autofill`).
    static func logPasskeyDiagnostic(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return
        }
        let fileURL = documents.appendingPathComponent("passkey-diagnostics.log")
        // Keep the diagnostic trace bounded: it is a debugging aid, not a log store.
        let maximumSize = 64 * 1024
        let existingSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if existingSize + line.utf8.count > maximumSize {
            try? Data(line.utf8).write(to: fileURL, options: .atomic)
            return
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: fileURL, options: .atomic)
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
        searchQuery: String,
        emptyStatus: String? = nil
    ) {
        guard !records.isEmpty || !searchQuery.isEmpty else {
            configureStatusView(
                title: "Monica",
                status: emptyStatus ?? "没有匹配的凭据"
            )
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

    enum PasskeyUserVerification: Equatable {
        case verified
        case unavailable
        case cancelled
    }

    /// Runs device-owner verification (biometrics with passcode fallback) and reports why it
    /// failed, so callers can degrade instead of blocking the whole credential request.
    /// Local Authentication refuses to show its UI (`LAError.notInteractive`) while the
    /// extension's view controller has not been presented yet, so wait until the AutoFill
    /// sheet is actually on screen before asking for the device owner.
    private func verifyDeviceOwnerAfterAppearing(reason: String) async -> PasskeyUserVerification {
        for _ in 0..<40 where !hasAppeared {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        if !hasAppeared {
            Self.logPasskeyDiagnostic("verification skipped: interface never appeared")
        }
        return await Self.verifyDeviceOwner(reason: reason)
    }

    static func verifyDeviceOwner(reason: String) async -> PasskeyUserVerification {
        // `notInteractive` is usually a presentation-timing artefact, so give the system a
        // second chance with a fresh context before degrading to an unverified credential.
        for attempt in 1...2 {
            let context = LAContext()
            context.interactionNotAllowed = false
            var canEvaluateError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &canEvaluateError) else {
                logPasskeyDiagnostic(
                    "verification unavailable attempt=\(attempt) canEvaluate=\(canEvaluateError?.code ?? -1) "
                        + "desc=\(canEvaluateError?.localizedDescription ?? "nil")"
                )
                return .unavailable
            }
            do {
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                logPasskeyDiagnostic("verification verified attempt=\(attempt)")
                return .verified
            } catch let error as LAError {
                logPasskeyDiagnostic(
                    "verification failed attempt=\(attempt) LAError=\(error.code.rawValue) desc=\(error.localizedDescription)"
                )
                // Only an explicit user cancel should abort the ceremony.
                if error.code == .userCancel {
                    return .cancelled
                }
                if error.code == .notInteractive, attempt == 1 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                return .unavailable
            } catch {
                logPasskeyDiagnostic("verification failed attempt=\(attempt) error=\(error)")
                return .unavailable
            }
        }
        return .unavailable
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
