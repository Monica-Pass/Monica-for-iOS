import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let appGroupIdentifier = "group.monica-pass.monica"
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        collectIncomingItems()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "正在导入到 Monica"
        statusLabel.textAlignment = .center
        statusLabel.textColor = .label
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func collectIncomingItems() {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []

        guard !providers.isEmpty else {
            completeRequest()
            return
        }

        let group = DispatchGroup()
        let collector = ShareImportRequestCollector()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(
                    forTypeIdentifier: UTType.url.identifier,
                    options: nil
                ) { item, _ in
                    defer { group.leave() }
                    if let request = makeURLShareImportRequest(from: item) {
                        collector.append(request)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(
                    forTypeIdentifier: UTType.plainText.identifier,
                    options: nil
                ) { item, _ in
                    defer { group.leave() }
                    if let request = makeTextShareImportRequest(from: item) {
                        collector.append(request)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let typeIdentifier = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
                group.enter()
                provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier,
                    options: nil
                ) { item, _ in
                    defer { group.leave() }
                    if let request = makeFileShareImportRequest(
                        from: item,
                        mediaType: typeIdentifier
                    ) {
                        collector.append(request)
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.persistAndComplete(collector.snapshot())
        }
    }

    private func persistAndComplete(_ requests: [AppShareImportRequest]) {
        guard !requests.isEmpty else {
            completeRequest()
            return
        }
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            cancelRequest("App Group 容器不可用。")
            return
        }

        do {
            try AppShareExtensionInboxStore(containerURL: containerURL)
                .saveIncomingItems(requests)
            completeRequest()
        } catch {
            cancelRequest(error.localizedDescription)
        }
    }

    private func completeRequest() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancelRequest(_ message: String) {
        statusLabel.text = message
        let error = NSError(
            domain: "MonicaShareExtension",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        extensionContext?.cancelRequest(withError: error)
    }
}

private final class ShareImportRequestCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AppShareImportRequest] = []

    func append(_ request: AppShareImportRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func snapshot() -> [AppShareImportRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private func makeURLShareImportRequest(from item: NSSecureCoding?) -> AppShareImportRequest? {
    if let url = item as? URL {
        return .url(url)
    }
    if let value = item as? String, let url = URL(string: value) {
        return .url(url)
    }
    if let data = item as? Data,
       let value = String(data: data, encoding: .utf8),
       let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return .url(url)
    }
    return nil
}

private func makeTextShareImportRequest(from item: NSSecureCoding?) -> AppShareImportRequest? {
    if let value = item as? String {
        return .text(value)
    }
    if let data = item as? Data,
       let value = String(data: data, encoding: .utf8) {
        return .text(value)
    }
    return nil
}

private func makeFileShareImportRequest(
    from item: NSSecureCoding?,
    mediaType: String
) -> AppShareImportRequest? {
    guard let url = item as? URL else {
        return nil
    }
    return .file(url: url, mediaType: mediaType)
}
