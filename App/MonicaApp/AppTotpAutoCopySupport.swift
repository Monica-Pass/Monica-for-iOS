import Foundation
import MonicaCore

/// #148「验证码到期自动复制下一个码」的 App 层接线。
///
/// 验证器页每秒调用一次 `tickTotpAutoCopy`；真正的门控、去重与写入都在
/// `TotpAutoCopyController` / `TotpAutoCopyPolicy`（MonicaCore）里，便于用固定时钟测试。
extension AppSessionModel {
    /// 是否有“手动复制过、可以自动续写”的条目。设置页用它决定是否提示“复制一次验证码后生效”。
    var hasArmedTotpAutoCopyEntry: Bool {
        totpAutoCopyController.isArmed
    }

    /// 每秒一次的前台轮询。
    ///
    /// 只有开关打开、库已解锁、scene 为 active、验证器页可见、条目是 TOTP 且剪贴板
    /// 仍是本 App 写入的值时才会真正写剪贴板；同一周期最多写一次。
    @discardableResult
    func tickTotpAutoCopy(
        now: Date = Date(),
        isSceneActive: Bool,
        isAuthenticatorPageVisible: Bool
    ) -> TotpAutoCopyOutcome {
        let storageEntry = totpAutoCopyController.armedEntryIdentifier
            .flatMap { entryID in totpEntries.first(where: { $0.id == entryID }) }
        let entry = storageEntry.map { storageEntry in
            TotpAutoCopyController.Entry(
                entryID: storageEntry.id,
                period: Int(storageEntry.period),
                isHOTP: otpType(for: storageEntry) != .totp
            )
        }
        let request = TotpAutoCopyController.Request(
            isEnabled: totpAutoCopyEnabled,
            isVaultUnlocked: vaultState == .unlocked,
            isSceneActive: isSceneActive,
            isAuthenticatorPageVisible: isAuthenticatorPageVisible,
            ttl: sensitiveClipboardTTL,
            now: now
        )
        let outcome = totpAutoCopyController.tick(request, entry: entry) { nextCode in
            guard let storageEntry else {
                return ""
            }
            return try totpCode(for: storageEntry, at: nextCode.validFrom)
        }
        if case .copied = outcome {
            sensitivePasteboardDidCopyAutomatically()
        }
        return outcome
    }
}
