import Foundation
import Testing
@testable import MonicaWidgetShared

@Suite("Widget 验证码进度条样式快照")
struct MonicaWidgetProgressStyleTests {
    private func decode(_ json: String) throws -> MonicaWidgetSnapshot {
        try JSONDecoder().decode(MonicaWidgetSnapshot.self, from: #require(json.data(using: .utf8)))
    }

    // MARK: - 样式字段

    @Test func styleRoundTripsThroughJSON() throws {
        let snapshot = MonicaWidgetSnapshot(
            vaultState: .unlocked,
            totalEntryCount: 1,
            totpItems: [
                MonicaWidgetTotpItem(
                    id: "totp-1",
                    title: "GitHub",
                    issuer: "GitHub",
                    accountName: "alice@example.com",
                    secondsRemaining: 12,
                    period: 30
                )
            ],
            totpProgressStyle: .circular
        )

        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // 写入的是稳定 rawValue，Widget 扩展与 App 都按它解析。
        #expect(object["totpProgressStyle"] as? String == "circular")

        let decoded = try JSONDecoder().decode(MonicaWidgetSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(decoded.totpProgressStyle == .circular)
    }

    @Test func legacySnapshotWithoutStyleDecodesAsLinear() throws {
        // 旧版本 App 写出的快照：没有 totpProgressStyle，也没有 period。
        let payload = """
        {
          "vaultState" : "unlocked",
          "totalEntryCount" : 1,
          "totpItems" : [
            { "id" : "totp-1", "title" : "GitHub", "issuer" : "GitHub", "accountName" : "alice", "secondsRemaining" : 9 }
          ]
        }
        """
        let snapshot = try decode(payload)

        #expect(snapshot.totpProgressStyle == .linear)
        #expect(snapshot.totpItems.first?.period == MonicaWidgetTotpItem.defaultPeriod)
    }

    @Test func unknownStyleValueFallsBackToLinear() throws {
        let payload = """
        { "vaultState" : "unlocked", "totpProgressStyle" : "wave" }
        """
        #expect(try decode(payload).totpProgressStyle == .linear)
    }

    @Test func snapshotValueInitialiserHandlesMissingAndUnknown() {
        #expect(MonicaWidgetTotpProgressStyle(snapshotValue: nil) == .linear)
        #expect(MonicaWidgetTotpProgressStyle(snapshotValue: "circular") == .circular)
        #expect(MonicaWidgetTotpProgressStyle(snapshotValue: "LINEAR") == .linear)
        #expect(MonicaWidgetTotpProgressStyle.allCases == [.linear, .circular])
    }

    // MARK: - 周期字段

    @Test func periodRoundTripsAndComputesFraction() throws {
        let item = MonicaWidgetTotpItem(
            id: "totp-1",
            title: "GitHub",
            issuer: "GitHub",
            accountName: "alice@example.com",
            secondsRemaining: 45,
            period: 60
        )
        #expect(item.period == 60)
        #expect(item.progressFraction == 0.75)

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(MonicaWidgetTotpItem.self, from: data)
        #expect(decoded == item)
    }

    @Test func invalidPeriodIsClampedAndFractionStaysInRange() throws {
        // 手工编辑 / 未来写入方给出的非法周期不能让 Widget 崩溃或画出反向进度。
        let zero = MonicaWidgetTotpItem(
            id: "totp-1",
            title: "",
            issuer: "",
            accountName: "",
            secondsRemaining: 5,
            period: 0
        )
        #expect(zero.period == 1)
        #expect(zero.progressFraction == 1)

        let overrun = MonicaWidgetTotpItem(
            id: "totp-1",
            title: "",
            issuer: "",
            accountName: "",
            secondsRemaining: 99,
            period: 30
        )
        #expect(overrun.progressFraction == 1)

        let payload = """
        {
          "id" : "totp-1", "title" : "", "issuer" : "", "accountName" : "",
          "secondsRemaining" : 5, "period" : -12
        }
        """
        let decoded = try JSONDecoder().decode(
            MonicaWidgetTotpItem.self,
            from: #require(payload.data(using: .utf8))
        )
        #expect(decoded.period == 1)
    }
}
