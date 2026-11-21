import AuthenticationServices
import LocalAuthentication
import MonicaCore
import MonicaSecurity
import MonicaStorage
import UIKit

final class AutoFillCredentialProviderViewController: ASCredentialProviderViewController, UISearchBarDelegate {
    /// iOS rejects provider passkeys whose authenticator data never declares the backup flags,
    /// so the credential advertises multi-device capability. Keep this in sync with how the
    /// passkey key material is stored.
    private enum PasskeyBackupDeclaration {
        static let isEligible = true
        static let isBackedUp = true
    }

    private let appGroupIdentifier = "group.com.monicapass.monica"
    /// App group used by the diagnostics spool. The spool resolves the container URL itself
    /// and only ever receives closed codes plus allowlisted metadata.
    private static let passkeyDiagnosticAppGroupIdentifier = "group.com.monicapass.monica"
    private var loadTask: Task<Void, Never>?
    private var passkeyListTask: Task<Void, Never>?
    private var credentialResolver: AutoFillCredentialResolver?
    private var matchedCredentialRecords: [AutoFillCredentialIndexRecord] = []
    /// 最近一次加载的域名规则（#40）。静默填充路径用它做二次校验；
    /// 尚未加载时为空集合，按「不限制」处理（fail-open），避免规则存储故障把自动填充彻底打断。
    private var domainRules: AutoFillDomainRuleSet = .empty
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
        guard !domainRules.hidesServiceIdentifier(credentialIdentity.serviceIdentifier.identifier) else {
            // 被域名规则屏蔽的站点不允许静默填充；交回系统 UI，由列表页给出明确原因。
            cancelRequest(code: ASExtensionError.Code.userInteractionRequired)
            return
        }

        // #146：静默路径没有交互机会，无法在返回密码前验证设备所有者。
        // 开关打开时把请求交回系统 UI，由用户点选凭据后走一次验证，绝不直接给密码。
        guard deviceVerificationPolicy.authorizeSilentFill().isAuthorized else {
            cancelRequest(code: ASExtensionError.Code.userInteractionRequired)
            return
        }

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
                status: String(localized: "需要验证设备所有者后才能使用通行密钥")
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
                    status: String(localized: "Passkey 身份不可用，请回到 Monica 检查凭据状态")
                )
                cancelRequest(code: ASExtensionError.Code.credentialIdentityNotFound)
            }
            return
        }

        configureStatusView(title: "Monica", status: String(localized: "此凭据请求需要在 Monica 中完成"))
    }

    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        guard let passkeyRequest = registrationRequest as? ASPasskeyCredentialRequest else {
            configureStatusView(title: "Monica Passkey", status: String(localized: "Passkey 注册请求已收到"))
            return
        }

        let relyingPartyID = relyingPartyID(for: passkeyRequest)
        guard passkeyRequest.supportedAlgorithms.contains(.ES256) else {
            Self.logPasskeyDiagnostic(
                .passkeyRegistrationFailed,
                level: .warning,
                metadata: .merged(.stage(.register), .reason(.unsupported))
            )
            configurePasskeyStatusView(
                relyingPartyID: relyingPartyID,
                status: String(localized: "此站点要求的签名算法不受支持")
            )
            cancelRequest(code: ASExtensionError.Code.failed)
            return
        }

        beginPasskeyRegistration(passkeyRequest, relyingPartyID: relyingPartyID)
    }

    private func beginPasskeyRegistration(
        _ passkeyRequest: ASPasskeyCredentialRequest,
        relyingPartyID: String
    ) {
        configurePasskeyStatusView(
            relyingPartyID: relyingPartyID,
            status: String(localized: "正在验证设备所有者")
        )
        Task { @MainActor [weak self] in
            let verification = await self?.verifyDeviceOwnerAfterAppearing(
                reason: String(localized: "为 \(relyingPartyID) 创建 Monica 通行密钥")
            ) ?? .unavailable
            guard let self, verification != .cancelled else {
                Self.logPasskeyDiagnostic(
                    .passkeyDeviceOwnerVerificationFailed,
                    level: .info,
                    metadata: .merged(.stage(.verifyDeviceOwner), .reason(.cancelled))
                )
                self?.cancelRequest(code: ASExtensionError.Code.userCanceled)
                return
            }
            // A relying party that lists one of our credentials in excludedCredentials must
            // not receive a duplicate passkey for the same account.
            if await self.matchesExcludedCredential(passkeyRequest) {
                Self.logPasskeyDiagnostic(
                    .passkeyRegistrationFailed,
                    level: .info,
                    metadata: .merged(.stage(.register), .reason(.policyBlocked))
                )
                self.configurePasskeyStatusView(
                    relyingPartyID: relyingPartyID,
                    status: String(localized: "此账号已有通行密钥，无需重复创建")
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
        statusLabel.text = String(localized: "保险库已锁定")
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
        configureStatusView(title: "Monica", status: String(localized: "正在解锁自动填充"))
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
                let matchedRecords = resolver.records(
                    matchingServiceIdentifiers: serviceIdentifiers.map(\.identifier)
                )
                let rules = await Self.loadDomainRules(vaultID: unlockedData.index.vaultID)
                let requestIdentifiers = serviceIdentifiers.map(\.identifier)
                let requestFullyBlocked = !requestIdentifiers.isEmpty
                    && requestIdentifiers.allSatisfy { rules.hidesServiceIdentifier($0) }
                let records = matchedRecords.filter { record in
                    record.serviceIdentifiers.contains { !rules.hidesServiceIdentifier($0) }
                }
                let blockedStatus = requestFullyBlocked
                    ? String(localized: "该网站已被「自动填充域名规则」屏蔽。可在 Monica 设置 → 自动填充中调整。")
                    : nil
                await MainActor.run {
                    self.credentialResolver = resolver
                    self.domainRules = rules
                    self.matchedCredentialRecords = records
                    if let preferredRecordIdentifier,
                       (try? resolver.credential(recordIdentifier: preferredRecordIdentifier)) != nil {
                        // #146：命中用户点选的那条记录时同样要先过门禁。
                        // 开关关闭时这里直接返回密码，与历史行为一致；打开时先验证设备所有者。
                        self.completePasswordCredentialAfterDeviceVerification(
                            recordIdentifier: preferredRecordIdentifier
                        )
                        return
                    }
                    self.configureCredentialList(
                        records,
                        searchQuery: "",
                        emptyStatus: blockedStatus ?? emptyStatus
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

    /// 读取用户在 Monica 里配置的自动填充域名规则（#40）。
    ///
    /// 规则存 Keychain；读取失败时返回空集合（fail-open），并且不把任何规则内容写进日志。
    private static func loadDomainRules(vaultID: String) async -> AutoFillDomainRuleSet {
        let store = KeychainAutoFillDomainRuleStore()
        guard let payload = try? await store.loadPayload(vaultID: vaultID) else {
            return .empty
        }
        return (try? AutoFillDomainRuleCodec.decode(payload)) ?? .empty
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
            reason: String(localized: "解锁 Monica 自动填充")
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

    private struct StatusAction {
        let title: String
        let handler: () -> Void
    }

    private func configureStatusView(
        title: String,
        status: String,
        actions: [StatusAction] = []
    ) {
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

        var arrangedSubviews: [UIView] = [titleLabel, statusLabel]
        for action in actions {
            let button = UIButton(type: .system)
            button.setTitle(action.title, for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            button.addAction(UIAction { _ in action.handler() }, for: .touchUpInside)
            arrangedSubviews.append(button)
        }

        let stack = UIStackView(arrangedSubviews: arrangedSubviews)
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
                userVerified: userVerified,
                backupEligible: PasskeyBackupDeclaration.isEligible,
                backupState: PasskeyBackupDeclaration.isBackedUp
            )
            let credential = ASPasskeyRegistrationCredential(
                relyingParty: registration.relyingPartyID,
                clientDataHash: request.clientDataHash,
                credentialID: registration.credentialID,
                attestationObject: registration.attestationObject
            )
            Self.logPasskeyDiagnostic(
                .passkeyRegistrationSucceeded,
                level: .info,
                metadata: .merged(.stage(.register), .flag(userVerified))
            )
            // Finish the ceremony before touching the credential identity store: mutating it
            // while the request is still in flight makes the platform abort the WebAuthn call.
            extensionContext.completeRegistrationRequest(using: credential) { [weak self] expired in
                Self.logPasskeyDiagnostic(
                    .passkeyRegistrationSucceeded,
                    level: .info,
                    metadata: .merged(.stage(.register), .flag(expired))
                )
                guard let self, !expired else {
                    return
                }
                do {
                    try self.persistPasskeyRegistration(registration)
                } catch {
                    Self.logPasskeyDiagnostic(
                        .passkeyInboxPersistFailed,
                        level: .warning,
                        metadata: .merged(.stage(.register), .reason(.storage))
                    )
                }
                self.savePasskeyIdentity(for: registration)
            }
        } catch {
            configurePasskeyStatusView(
                relyingPartyID: relyingPartyID(for: request),
                status: String(localized: "Passkey 注册失败，请回到 Monica 检查凭据状态")
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
            status: String(localized: "正在读取通行密钥")
        )

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
            Self.logPasskeyDiagnostic(
                .passkeyAssertionStarted,
                level: .info,
                metadata: .merged(.stage(.assert), .count(candidates.count))
            )
            guard !candidates.isEmpty else {
                let emptyStatus = passkeyIdentities.isEmpty
                    ? String(localized: "Monica 中没有该站点的通行密钥，可改用密码或重新注册。")
                    : String(localized: "此站点的通行密钥不在 Monica 中（可能保存在 iCloud 钥匙串），可改用密码或重新注册。")
                self.loadMatchingCredentialIndexRecords(
                    for: fallbackServiceIdentifiers,
                    emptyStatus: emptyStatus
                )
                return
            }

            let note = allowedMatches.isEmpty
                ? String(localized: "网站请求的凭据不在 Monica 中，以下为该站点的其他通行密钥。")
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
            status: String(localized: "正在验证设备所有者")
        )
        Task { @MainActor [weak self] in
            let verification = await self?.verifyDeviceOwnerAfterAppearing(
                reason: String(localized: "使用 Monica 通行密钥登录 \(relyingPartyID)")
            ) ?? .unavailable
            guard let self, verification != .cancelled else {
                Self.logPasskeyDiagnostic(
                    .passkeyAssertionFailed,
                    level: .info,
                    metadata: .merged(.stage(.verifyDeviceOwner), .reason(.cancelled))
                )
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
                userVerified: userVerified,
                backupEligible: PasskeyBackupDeclaration.isEligible,
                backupState: PasskeyBackupDeclaration.isBackedUp
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
                .passkeyAssertionSucceeded,
                level: .info,
                metadata: .merged(.stage(.assert), .flag(userVerified))
            )
            extensionContext.completeAssertionRequest(
                using: credential,
                completionHandler: nil
            )
        } catch {
            Self.logPasskeyDiagnostic(
                .passkeyAssertionFailed,
                level: .error,
                metadata: .merged(.stage(.assert), .reason(.commandFailed))
            )
            configurePasskeyStatusView(
                relyingPartyID: identity.relyingPartyIdentifier,
                status: String(localized: "Passkey 认证失败，请回到 Monica 检查凭据状态")
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
                Self.logPasskeyDiagnostic(
                    .passkeyIdentityUnavailable,
                    level: .warning,
                    metadata: .merged(.stage(.register), .reason(.policyBlocked))
                )
                return
            }
            ASCredentialIdentityStore.shared.saveCredentialIdentities(identities) { success, error in
                if success {
                    Self.logPasskeyDiagnostic(
                        .passkeyRegistrationSucceeded,
                        level: .info,
                        metadata: .stage(.register)
                    )
                } else {
                    Self.logPasskeyDiagnostic(
                        .passkeyIdentityUnavailable,
                        level: .warning,
                        metadata: .merged(.stage(.register), .reason(.storage))
                    )
                }
            }
        }
    }

    /// Records one structured passkey event into the shared app-group spool.
    /// It never writes messages, credential IDs, usernames or raw errors: the spool only
    /// carries a closed event code plus allowlisted metadata, and the app imports it when
    /// the developer section is opened.
    nonisolated static func logPasskeyDiagnostic(
        _ code: DiagnosticCode,
        level: DiagnosticLevel = .info,
        metadata: DiagnosticMetadata = DiagnosticMetadata()
    ) {
        guard let fileURL = DiagnosticEventSpool.defaultFileURL(
            appGroupIdentifier: passkeyDiagnosticAppGroupIdentifier
        ) else {
            return
        }
        let spool = DiagnosticEventSpool(fileURL: fileURL)
        _ = spool.append(
            DiagnosticEvent(
                timestamp: Date(),
                level: level,
                module: .passkey,
                code: code,
                metadata: metadata
            )
        )
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
                status: String(localized: "自动填充保存请求已交给 Monica")
            )
            if allowsCompletion {
                extensionContext.completeSavePasswordRequest(completionHandler: nil)
            }
        } catch {
            configureStatusView(
                title: "Monica",
                status: String(localized: "自动填充保存失败，请稍后在 Monica 中重试")
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
                status: emptyStatus ?? String(localized: "没有匹配的凭据")
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
        searchBar.placeholder = String(localized: "搜索")
        searchBar.searchTextField.text = searchQuery
        searchBar.delegate = self

        let stack = UIStackView(arrangedSubviews: [titleLabel, searchBar])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12

        if records.isEmpty {
            let emptyLabel = UILabel()
            emptyLabel.text = String(localized: "无结果")
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
        // #146：列表点选也要过门禁；开关关闭时这里等价于历史行为（直接返回密码）。
        completePasswordCredentialAfterDeviceVerification(recordIdentifier: record.id)
    }

    /// 「自动填充前要求设备验证」的当前取值（#146）。
    ///
    /// 每次填充都重新读一次 App Group 共享偏好：用户在 Monica 里改了开关后，
    /// 下一次填充立即生效，扩展不缓存这个值，也不缓存任何验证结果。
    private var deviceVerificationPolicy: AutoFillDeviceVerificationPolicy {
        AutoFillDeviceVerificationPolicy(
            requiresVerificationBeforeFilling: AutoFillDeviceVerificationPreferenceStore()
                .requiresVerificationBeforeFilling
        )
    }

    /// 返回密码前的唯一门禁（#146）。
    ///
    /// - 开关关闭：立即按历史行为返回密码。
    /// - 开关打开：先做一次设备所有者验证（Face ID / Touch ID / 设备口令），
    ///   只有验证通过才读取并返回密码；取消、失败、不可用一律不返回密码。
    private func completePasswordCredentialAfterDeviceVerification(recordIdentifier: String) {
        let policy = deviceVerificationPolicy
        guard policy.requiresVerificationBeforeFilling else {
            completePasswordCredential(recordIdentifier: recordIdentifier)
            return
        }

        configureStatusView(title: "Monica", status: "正在验证设备所有者…")
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let verification = await self.verifyDeviceOwnerAfterAppearing(
                reason: "验证设备所有者后才能返回 Monica 中的密码",
                // 密码门禁不写通行密钥诊断：这里不是通行密钥流程，也不记录验证结果。
                logsDiagnostics: false
            )
            switch policy.authorizeInteractiveFill(after: verification.deviceVerificationOutcome) {
            case .authorized(var grant):
                // 一次验证只放行一次填充：结果既不缓存，也不复用。
                guard grant.consume() else {
                    return
                }
                self.completePasswordCredential(recordIdentifier: recordIdentifier)
            case .refused(let failure):
                self.showDeviceVerificationFailure(
                    failure,
                    recordIdentifier: recordIdentifier
                )
            case .interactionRequired:
                self.cancelRequest(code: ASExtensionError.Code.userInteractionRequired)
            }
        }
    }

    /// 唯一把密码交给系统的位置：调用方必须先通过 `completePasswordCredentialAfterDeviceVerification`。
    private func completePasswordCredential(recordIdentifier: String) {
        do {
            guard let secret = try credentialResolver?.credential(recordIdentifier: recordIdentifier) else {
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

    /// 验证没通过时的诚实降级：绝不返回密码，并明确告诉用户为什么。
    private func showDeviceVerificationFailure(
        _ failure: AutoFillDeviceVerificationFailure,
        recordIdentifier: String
    ) {
        switch failure {
        case .userCancelled:
            cancelRequest(code: ASExtensionError.Code.userCanceled)
        case .verificationUnavailable:
            configureStatusView(
                title: "Monica",
                status: failure.message,
                actions: [
                    StatusAction(title: "关闭") { [weak self] in
                        self?.cancelRequest(code: ASExtensionError.Code.failed)
                    }
                ]
            )
        case .verificationFailed:
            configureStatusView(
                title: "Monica",
                status: failure.message,
                actions: [
                    StatusAction(title: "重试") { [weak self] in
                        self?.completePasswordCredentialAfterDeviceVerification(
                            recordIdentifier: recordIdentifier
                        )
                    },
                    StatusAction(title: "关闭") { [weak self] in
                        self?.cancelRequest(code: ASExtensionError.Code.failed)
                    }
                ]
            )
        }
    }

    /// 设备所有者验证结果。通行密钥与密码填充共用同一套 `LAContext` 封装（#146），
    /// 不重复实现第二份验证逻辑。
    enum AutoFillDeviceOwnerVerification: Equatable {
        case verified
        case unavailable
        case failed
        case cancelled

        var deviceVerificationOutcome: AutoFillDeviceVerificationOutcome {
            switch self {
            case .verified:
                return .verified
            case .unavailable:
                return .unavailable
            case .failed:
                return .failed
            case .cancelled:
                return .cancelled
            }
        }
    }

    /// Runs device-owner verification (biometrics with passcode fallback) and reports why it
    /// failed, so callers can degrade instead of blocking the whole credential request.
    /// Local Authentication refuses to show its UI (`LAError.notInteractive`) while the
    /// extension's view controller has not been presented yet, so wait until the AutoFill
    /// sheet is actually on screen before asking for the device owner.
    private func verifyDeviceOwnerAfterAppearing(
        reason: String,
        logsDiagnostics: Bool = true
    ) async -> AutoFillDeviceOwnerVerification {
        for _ in 0..<40 where !hasAppeared {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        if !hasAppeared, logsDiagnostics {
            Self.logPasskeyDiagnostic(
                .passkeyDeviceOwnerVerificationFailed,
                level: .info,
                metadata: .merged(.stage(.verifyDeviceOwner), .reason(.interactionRequired))
            )
        }
        return await Self.verifyDeviceOwner(reason: reason, logsDiagnostics: logsDiagnostics)
    }

    static func verifyDeviceOwner(
        reason: String,
        logsDiagnostics: Bool = true
    ) async -> AutoFillDeviceOwnerVerification {
        // `notInteractive` is usually a presentation-timing artefact, so give the system a
        // second chance with a fresh context before degrading to an unverified credential.
        for attempt in 1...2 {
            let context = LAContext()
            context.interactionNotAllowed = false
            var canEvaluateError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &canEvaluateError) else {
                if logsDiagnostics {
                    logPasskeyDiagnostic(
                        .passkeyDeviceOwnerVerificationFailed,
                        level: .warning,
                        metadata: .merged(
                            .stage(.verifyDeviceOwner),
                            .reason(.policyBlocked),
                            .status(canEvaluateError?.code ?? -1)
                        )
                    )
                }
                return .unavailable
            }
            do {
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)

                return .verified
            } catch let error as LAError {
                if logsDiagnostics {
                    logPasskeyDiagnostic(
                        .passkeyDeviceOwnerVerificationFailed,
                        level: .warning,
                        metadata: .merged(
                            .stage(.verifyDeviceOwner),
                            .reason(.verificationFailed),
                            .status(Int(error.code.rawValue))
                        )
                    )
                }
                // 只有用户主动取消才算取消；设备没有可用的验证方式归为 unavailable，
                // 其余（匹配失败、系统取消、锁定等）归为 failed，好让密码门禁给出对应文案。
                if error.code == .userCancel {
                    return .cancelled
                }
                switch error.code {
                case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                    return .unavailable
                case .notInteractive:
                    if attempt == 1 {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        continue
                    }
                    return .unavailable
                default:
                    return .failed
                }
            } catch {
                if logsDiagnostics {
                    logPasskeyDiagnostic(
                        .passkeyDeviceOwnerVerificationFailed,
                        level: .warning,
                        metadata: .merged(.stage(.verifyDeviceOwner), .reason(.commandFailed))
                    )
                }
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
            return String(localized: "无法访问共享数据，请重新打开 Monica 后再试。")
        case .indexUnavailable:
            return String(localized: "自动填充索引不可用。")
        case .credentialSecretsUnavailable:
            return String(localized: "自动填充凭据密钥不可用。")
        case .credentialSecretUnavailable:
            return String(localized: "自动填充凭据密钥不可用。")
        case .passkeyIdentityUnavailable:
            return String(localized: "Passkey 身份不可用。")
        }
    }
}
