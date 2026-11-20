import Foundation
import Testing
@testable import MonicaCore

@Suite("App Store 更新检查")
struct AppStoreUpdateTests {

    // MARK: - 版本比较

    @Test func parsesMarketingVersions() throws {
        #expect(try #require(AppMarketingVersion(string: "1")).description == "1")
        #expect(try #require(AppMarketingVersion(string: "1.2")).description == "1.2")
        #expect(try #require(AppMarketingVersion(string: "1.2.3")).description == "1.2.3")
        #expect(try #require(AppMarketingVersion(string: " 1.2 ")).description == "1.2")
        // build 段与后缀不参与比较，但版本本身必须仍然可解析。
        #expect(try #require(AppMarketingVersion(string: "1.2.3.4")).description == "1.2.3")
        #expect(try #require(AppMarketingVersion(string: "2.0.0-beta")).description == "2")
    }

    @Test func rejectsNonNumericVersions() {
        #expect(AppMarketingVersion(string: "") == nil)
        #expect(AppMarketingVersion(string: "   ") == nil)
        #expect(AppMarketingVersion(string: "abc") == nil)
        #expect(AppMarketingVersion(string: "1..2") == nil)
        #expect(AppMarketingVersion(string: "1.2.x") == nil)
        #expect(AppMarketingVersion(string: "1.2.3.4.5") == nil)
        #expect(AppMarketingVersion(string: "-1.2") == nil)
    }

    @Test func comparesNumericallyNotLexicographically() throws {
        let oneTwo = try #require(AppMarketingVersion(string: "1.2"))
        let oneTen = try #require(AppMarketingVersion(string: "1.10"))
        let twoZero = try #require(AppMarketingVersion(string: "2.0"))
        let oneNinetyNine = try #require(AppMarketingVersion(string: "1.99"))

        #expect(oneTwo < oneTen)
        #expect(oneTen == oneTen)
        #expect(twoZero > oneNinetyNine)
        #expect(try #require(AppMarketingVersion(string: "1.2")) == AppMarketingVersion(string: "1.2.0"))
    }

    // MARK: - 查询

    @Test func reportsUpdateWhenStoreVersionIsNewer() async throws {
        let recorder = RequestRecorder()
        let checker = AppStoreUpdateChecker(
            appStoreID: "1234567890",
            countryCode: "cn",
            transport: AppStoreLookupTransport { request in
                await recorder.record(request)
                return (Self.lookupJSON(version: "1.10", url: "https://apps.apple.com/cn/app/id1234567890"), Self.httpResponse(200))
            }
        )

        let availability = await checker.checkForUpdate(currentVersion: "1.2")

        guard case let .updateAvailable(current, latest, storeURL) = availability else {
            Issue.record("expected updateAvailable, got \(availability)")
            return
        }
        #expect(current == "1.2")
        #expect(latest == "1.10")
        #expect(storeURL.absoluteString == "https://apps.apple.com/cn/app/id1234567890")

        let request = try #require(await recorder.lastRequest())
        let url = try #require(request.url)
        #expect(url.scheme == "https")
        #expect(url.host == "itunes.apple.com")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "id", value: "1234567890")))
        #expect(query.contains(URLQueryItem(name: "country", value: "CN")))
    }

    @Test func reportsUpToDateWhenVersionsMatch() async {
        let checker = Self.checker(storeVersion: "1.10", url: "https://apps.apple.com/app/id1")
        let availability = await checker.checkForUpdate(currentVersion: "1.10")

        #expect(availability == .upToDate(currentVersion: "1.10", latestVersion: "1.10"))
    }

    @Test func doesNotOfferDowngradeWhenStoreVersionIsOlder() async {
        let checker = Self.checker(storeVersion: "1.9", url: "https://apps.apple.com/app/id1")
        let availability = await checker.checkForUpdate(currentVersion: "1.10")

        #expect(availability == .upToDate(currentVersion: "1.10", latestVersion: "1.9"))
    }

    @Test func refusesNonHTTPSStoreLink() async {
        let checker = Self.checker(storeVersion: "2.0", url: "http://apps.apple.com/app/id1")
        let availability = await checker.checkForUpdate(currentVersion: "1.0")

        #expect(availability == .untrustedStoreURL(currentVersion: "1.0", latestVersion: "2.0"))
    }

    @Test func refusesStoreLinkOutsideAppleDomains() async {
        let checker = Self.checker(storeVersion: "2.0", url: "https://example.com/phish")
        let availability = await checker.checkForUpdate(currentVersion: "1.0")

        #expect(availability == .untrustedStoreURL(currentVersion: "1.0", latestVersion: "2.0"))
    }

    @Test func reportsNotFoundWhenLookupReturnsNoResult() async {
        let checker = AppStoreUpdateChecker(
            appStoreID: "42",
            transport: AppStoreLookupTransport { _ in
                (Data(#"{"resultCount":0,"results":[]}"#.utf8), Self.httpResponse(200))
            }
        )

        #expect(await checker.checkForUpdate(currentVersion: "1.0") == .notFoundInStore(currentVersion: "1.0"))
    }

    @Test func reportsNotConfiguredWithoutAppStoreIDAndNeverCallsNetwork() async {
        let counter = RequestCounter()
        let checker = AppStoreUpdateChecker(
            appStoreID: "   ",
            transport: AppStoreLookupTransport { request in
                await counter.increment(request)
                return (Data(), Self.httpResponse(200))
            }
        )

        let availability = await checker.checkForUpdate(currentVersion: "1.0")

        #expect(availability == .notConfigured(currentVersion: "1.0"))
        #expect(await counter.count == 0)
    }

    @Test func mapsHTTPFailure() async {
        let checker = AppStoreUpdateChecker(
            appStoreID: "42",
            transport: AppStoreLookupTransport { _ in
                (Data(), Self.httpResponse(503))
            }
        )

        #expect(
            await checker.checkForUpdate(currentVersion: "1.0")
                == .failed(currentVersion: "1.0", error: .httpStatus(503))
        )
    }

    @Test func mapsMalformedJSON() async {
        let checker = AppStoreUpdateChecker(
            appStoreID: "42",
            transport: AppStoreLookupTransport { _ in
                (Data("not json".utf8), Self.httpResponse(200))
            }
        )

        #expect(
            await checker.checkForUpdate(currentVersion: "1.0")
                == .failed(currentVersion: "1.0", error: .malformedResponse)
        )
    }

    @Test func mapsTransportErrorWithoutLeakingDetails() async {
        struct Boom: Error { let secret = "should-not-surface" }
        let checker = AppStoreUpdateChecker(
            appStoreID: "42",
            transport: AppStoreLookupTransport { _ in throw Boom() }
        )

        let availability = await checker.checkForUpdate(currentVersion: "1.0")
        guard case let .failed(_, error) = availability else {
            Issue.record("expected failed, got \(availability)")
            return
        }
        guard case let .transport(summary) = error else {
            Issue.record("expected transport error, got \(error)")
            return
        }
        #expect(!summary.contains("should-not-surface"))
        #expect(!summary.isEmpty)
    }

    @Test func reportsUnparsableCurrentVersion() async {
        let checker = Self.checker(storeVersion: "2.0", url: "https://apps.apple.com/app/id1")
        let availability = await checker.checkForUpdate(currentVersion: "dev-build")

        #expect(
            availability == .failed(currentVersion: "dev-build", error: .currentVersionUnparsable("dev-build"))
        )
    }

    // MARK: - Helpers

    private static func checker(storeVersion: String, url: String) -> AppStoreUpdateChecker {
        AppStoreUpdateChecker(
            appStoreID: "1",
            transport: AppStoreLookupTransport { _ in
                (lookupJSON(version: storeVersion, url: url), httpResponse(200))
            }
        )
    }

    private static func lookupJSON(version: String, url: String) -> Data {
        Data(
            """
            {"resultCount":1,"results":[{"version":"\(version)","minimumOsVersion":"17.0","trackViewUrl":"\(url)"}]}
            """.utf8
        )
    }

    private static func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://itunes.apple.com/lookup")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }
}

private actor RequestRecorder {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
    func lastRequest() -> URLRequest? { requests.last }
}

private actor RequestCounter {
    private(set) var count = 0
    func increment(_ request: URLRequest) { count += 1 }
}
