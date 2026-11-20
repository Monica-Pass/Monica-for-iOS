//
//  MonicaAuthenticatorActivityAttributes.swift
//  MonicaWidgetShared
//
//  ActivityKit 的 attributes / content state，App 与 widget extension 共用。
//
//  只放非敏感字段：
//  - `alias`：条目别名（标题/签发方/账号名），用户点开始时已经看得见的信息；
//  - 时间窗口与周期：用于让系统渲染倒计时。
//
//  刻意不放：OTP 密钥、当前验证码正文、任何可用于重算验证码的种子。
//  即便 Live Activity 的载荷落到系统存储里，也拿不到能生成验证码的东西。
//

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation

public struct MonicaAuthenticatorActivityAttributes: ActivityAttributes {
    /// 每个活动实例里可以更新的部分。
    public struct ContentState: Codable, Hashable, Sendable {
        /// 归一后的周期（秒）。
        public let period: Int
        /// 当前倒计时窗口的起点。
        public let windowStart: Date
        /// 当前倒计时窗口的终点。
        public let windowEnd: Date
        /// 本次试点结束的时间。
        public let sessionEndsAt: Date
        /// ActivityKit 的 `staleDate`。
        public let staleDate: Date

        public init(period: Int, windowStart: Date, windowEnd: Date, sessionEndsAt: Date, staleDate: Date) {
            self.period = period
            self.windowStart = windowStart
            self.windowEnd = windowEnd
            self.sessionEndsAt = sessionEndsAt
            self.staleDate = staleDate
        }

        public init(plan: MonicaAuthenticatorActivityPlan) {
            self.init(
                period: plan.period,
                windowStart: plan.windowStart,
                windowEnd: plan.windowEnd,
                sessionEndsAt: plan.sessionEndsAt,
                staleDate: plan.staleDate
            )
        }
    }

    /// 条目 id —— 只用来把活动对回列表里的哪一行。
    public let entryID: String
    /// 锁屏/灵动岛展示的别名，已经是清洗过的短文本。
    public let alias: String

    public init(entryID: String, alias: String) {
        self.entryID = entryID
        self.alias = alias
    }

    public init(plan: MonicaAuthenticatorActivityPlan) {
        self.init(entryID: plan.entry.id, alias: plan.alias)
    }

    /// 把活动实例还原成共享包里的计划类型，供状态机与视图复用。
    public func plan(with state: ContentState) -> MonicaAuthenticatorActivityPlan {
        MonicaAuthenticatorActivityPlan(
            entry: MonicaAuthenticatorActivityEntry(id: entryID, alias: alias, period: state.period),
            windowStart: state.windowStart,
            windowEnd: state.windowEnd,
            sessionEndsAt: state.sessionEndsAt,
            staleDate: state.staleDate
        )
    }
}
#endif
