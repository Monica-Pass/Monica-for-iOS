import AuthenticationServices
import MonicaCore
import MonicaSecurity
import MonicaStorage
import UIKit

final class AutoFillCredentialProviderViewController: ASCredentialProviderViewController, UISearchBarDelegate {
    private let appGroupIdentifier = "group.takagi.ru.monica"
    private var loadTask: Task<Void, Never>?
    private var credentialResolver: AutoFillCredentialResolver?
    private var matchedCredentialRecords: [AutoFillCredentialIndexRecord] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        configureLockedView()
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        loadMatchingCredentialIndexRecords(for: serviceIdentifiers)
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

    override func prepareInterfaceToProvideCredential(for credentialIdentity: ASPasswordCredentialIdentity) {
        loadMatchingCredentialIndexRecords(
            for: [credentialIdentity.serviceIdentifier],
            preferredRecordIdentifier: credentialIdentity.recordIdentifier
        )
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

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "App Group 容器不可用。"
        case .indexUnavailable:
            return "自动填充索引不可用。"
        case .credentialSecretsUnavailable:
            return "自动填充凭据密钥不可用。"
        case .credentialSecretUnavailable:
            return "自动填充凭据密钥不可用。"
        }
    }
}
