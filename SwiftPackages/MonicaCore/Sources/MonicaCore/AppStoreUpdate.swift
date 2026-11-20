import Foundation

/// Apple marketing version / build number comparison.
///
/// App Store 的 `version` 与 `CFBundleShortVersionString` 都是点分数字（如 `1.2`、`1.10.3`），
/// 直接按字符串比较会把 `1.10` 判成小于 `1.2`，所以这里逐段转成整数比较。
/// 规则与 Apple 的 marketing version 一致：最多三段数字；下划线/连字符之后的 build 后缀不参与比较。
public struct AppMarketingVersion: Comparable, Sendable, Hashable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// 解析 `1`、`1.2`、`1.2.3`（以及 `1.2.3.4` 这类带 build 段的值，第四段之后忽略）。
    /// 任何非数字段、空段或负数都会返回 `nil`，调用方必须把它当成“无法比较”，不要猜。
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), !trimmed.hasPrefix("+") else { return nil }

        // App Store 偶尔会返回带后缀的版本（如 `2.0.0-beta`），后缀不参与比较。
        let numericPrefix = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? trimmed
        let components = numericPrefix.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(components.count) else { return nil }

        var numbers: [Int] = []
        for component in components {
            guard let value = Int(component), value >= 0 else { return nil }
            numbers.append(value)
        }

        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    public static func < (lhs: AppMarketingVersion, rhs: AppMarketingVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public var description: String {
        patch == 0 && minor == 0 ? "\(major)" : (patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)")
    }
}

/// 一次 App Store Lookup 的结果条目（只保留检查更新需要的字段）。
public struct AppStoreLookupEntry: Decodable, Sendable, Equatable {
    public let version: String
    public let minimumOsVersion: String?
    public let trackViewURL: URL?

    public init(version: String, minimumOsVersion: String? = nil, trackViewURL: URL? = nil) {
        self.version = version
        self.minimumOsVersion = minimumOsVersion
        self.trackViewURL = trackViewURL
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case minimumOsVersion
        case trackViewURL = "trackViewUrl"
    }
}

public struct AppStoreLookupResponse: Decodable, Sendable, Equatable {
    public let resultCount: Int
    public let results: [AppStoreLookupEntry]

    public init(resultCount: Int, results: [AppStoreLookupEntry]) {
        self.resultCount = resultCount
        self.results = results
    }
}

/// 检查更新的可恢复错误。所有文案只描述类别，不携带响应体或请求头，避免把商店返回的原始数据带进 UI/日志。
public enum AppStoreUpdateError: Error, Sendable, Equatable {
    case transport(String)
    case httpStatus(Int)
    case malformedResponse
    case currentVersionUnparsable(String)
}

/// 检查更新的结论。UI 必须能区分“没有上架”“已是最新”“有新版本”“无法检查”四种情况，
/// 不允许把任何一种失败伪装成“已是最新”。
public enum AppUpdateAvailability: Sendable, Equatable {
    /// 没有配置 App Store ID（开发版、企业分发、尚未上架）。
    case notConfigured(currentVersion: String)
    /// 已配置 ID，但商店里查不到这个 App。
    case notFoundInStore(currentVersion: String)
    case upToDate(currentVersion: String, latestVersion: String)
    case updateAvailable(currentVersion: String, latestVersion: String, storeURL: URL)
    /// 商店返回了更新，但链接不是受信任的 HTTPS 地址：不提供打开入口，只报告异常。
    case untrustedStoreURL(currentVersion: String, latestVersion: String)
    case failed(currentVersion: String, error: AppStoreUpdateError)
}

/// App Store Lookup API 的传输层。用闭包而不是直接持有 `URLSession`，测试可以完全离线注入响应。
public struct AppStoreLookupTransport: Sendable {
    public typealias Load = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public let load: Load

    public init(load: @escaping Load) {
        self.load = load
    }

    public static let live = AppStoreLookupTransport { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppStoreUpdateError.malformedResponse
        }
        return (data, httpResponse)
    }
}

/// 通过 Apple 官方 iTunes Lookup API 检查是否有新版本。
///
/// 只做“查询 + 给一个商店链接”，不下载、不安装、不绕过商店：iOS 上应用无法自更新。
public struct AppStoreUpdateChecker: Sendable {
    public static let lookupEndpoint = URL(string: "https://itunes.apple.com/lookup")!

    public let appStoreID: String?
    public let countryCode: String?
    public let transport: AppStoreLookupTransport

    public init(
        appStoreID: String?,
        countryCode: String? = nil,
        transport: AppStoreLookupTransport = .live
    ) {
        let trimmedID = appStoreID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appStoreID = (trimmedID?.isEmpty == false) ? trimmedID : nil
        let trimmedCountry = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.countryCode = (trimmedCountry?.isEmpty == false) ? trimmedCountry : nil
        self.transport = transport
    }

    public func checkForUpdate(currentVersion: String) async -> AppUpdateAvailability {
        let current = currentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let appStoreID else {
            return .notConfigured(currentVersion: current)
        }
        guard let currentParsed = AppMarketingVersion(string: current) else {
            return .failed(currentVersion: current, error: .currentVersionUnparsable(current))
        }
        guard let request = Self.makeRequest(appStoreID: appStoreID, countryCode: countryCode) else {
            return .failed(currentVersion: current, error: .malformedResponse)
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.load(request)
        } catch let error as AppStoreUpdateError {
            return .failed(currentVersion: current, error: error)
        } catch {
            // 只保留错误类型，不把可能包含 URL 查询串的原始描述带进 UI。
            return .failed(
                currentVersion: current,
                error: .transport(String(describing: type(of: error)))
            )
        }

        guard (200...299).contains(response.statusCode) else {
            return .failed(currentVersion: current, error: .httpStatus(response.statusCode))
        }

        let lookup: AppStoreLookupResponse
        do {
            lookup = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
        } catch {
            return .failed(currentVersion: current, error: .malformedResponse)
        }

        guard lookup.resultCount > 0, let entry = lookup.results.first else {
            return .notFoundInStore(currentVersion: current)
        }
        guard let latestParsed = AppMarketingVersion(string: entry.version) else {
            return .failed(currentVersion: current, error: .malformedResponse)
        }

        guard latestParsed > currentParsed else {
            return .upToDate(currentVersion: current, latestVersion: entry.version)
        }

        guard let storeURL = entry.trackViewURL, Self.isTrustedStoreURL(storeURL) else {
            return .untrustedStoreURL(currentVersion: current, latestVersion: entry.version)
        }
        return .updateAvailable(currentVersion: current, latestVersion: entry.version, storeURL: storeURL)
    }

    static func makeRequest(appStoreID: String, countryCode: String?) -> URLRequest? {
        guard var components = URLComponents(url: lookupEndpoint, resolvingAgainstBaseURL: false) else { return nil }
        var items = [URLQueryItem(name: "id", value: appStoreID)]
        if let countryCode {
            items.append(URLQueryItem(name: "country", value: countryCode))
        }
        components.queryItems = items

        guard let url = components.url, url.scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// 只接受 API 返回的 https 链接；商店域名之外的地址一律不打开。
    static func isTrustedStoreURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "apps.apple.com" || host.hasSuffix(".apps.apple.com") || host == "itunes.apple.com"
    }

    /// 从 `Bundle.main` 读取商店 ID 的 key：不写死 ID，未上架时保持缺省。
    public static let bundledAppStoreIDInfoKey = "MonicaAppStoreID"
}
