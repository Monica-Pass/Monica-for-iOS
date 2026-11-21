import Foundation
import MonicaCore

// slice B: SensitiveValues 域（#58 敏感值复制与预览掩码），从 AppSessionModel.swift 逐字搬移。
// 注意：静态存储属性 sensitivePreviewMaskPlaceholder 仍留在类体内。
extension AppSessionModel {
    /// 列表、搜索结果与卡包摘要一律掩码，不依赖临时显示状态。
    func maskedSensitivePreview(_ value: String) -> String {
        value.isEmpty ? String(localized: "空") : Self.sensitivePreviewMaskPlaceholder
    }

    /// 详情页按「类别偏好 + 本次解锁会话的临时显示状态」决定显示掩码还是明文。
    func sensitivePreviewValue(_ value: String, category: SensitivePreviewCategory, entryID: String) -> String {
        guard !value.isEmpty else {
            return String(localized: "空")
        }
        let revealed = sensitivePreviewPreferences.allowsTemporaryReveal(category)
            && sensitivePreviewSession.isRevealed(entryID: entryID)
        return revealed ? value : Self.sensitivePreviewMaskPlaceholder
    }

    /// 详情页「显示敏感字段」开关能否使用：全部类别都被禁止时不给误触机会。
    var canTemporarilyRevealSensitiveFieldsInDetail: Bool {
        !sensitivePreviewPreferences.alwaysMask && sensitivePreviewPreferences.hasRevealableCategories
    }

    func isSensitivePreviewRevealed(entryID: String) -> Bool {
        sensitivePreviewSession.isRevealed(entryID: entryID)
    }

    func setSensitivePreviewRevealed(_ revealed: Bool, entryID: String) {
        sensitivePreviewSession.setRevealed(revealed, forEntryID: entryID)
    }

    /// 锁库时清空临时显示状态；不写入任何持久化存储。
    func resetSensitivePreviewReveal() {
        sensitivePreviewSession.reset()
    }

    func updateSensitivePreviewPreferences(_ preferences: SensitivePreviewPreferences) {
        sensitivePreviewPreferences = preferences
        sensitivePreviewPreferenceStore.savePreferences(preferences)
        if preferences.alwaysMask {
            sensitivePreviewSession.reset()
        }
        recordUserActivity()
    }

    func updateSensitiveClipboardTTL(_ ttl: SensitiveClipboardTTL) {
        sensitiveClipboardTTL = ttl
        sensitiveClipboardPreferenceStore.saveTTL(ttl)
        if ttl == .off {
            // 关闭自动清除后丢弃待清理记录，避免下一次回到前台时把仅剩的记录清掉。
            sensitivePasteboard.discardPendingRecord()
            sensitivePasteboardHasPendingAutoClear = false
            sensitivePasteboardExpiryTask?.cancel()
            sensitivePasteboardExpiryTask = nil
        }
        recordUserActivity()
    }

    /// #148：切换「验证码到期自动复制下一个」。
    ///
    /// 关闭不会清掉“记住的条目”：用户复制一次验证码、再打开开关时依然生效。
    func updateTotpAutoCopyEnabled(_ isEnabled: Bool) {
        guard totpAutoCopyEnabled != isEnabled else {
            return
        }
        totpAutoCopyEnabled = isEnabled
        totpAutoCopyPreferenceStore.saveIsEnabled(isEnabled)
        recordUserActivity()
    }

    /// #148：自动续写成功后同步 #58 的待清理状态，并复用同一套前台到期轮询。
    func sensitivePasteboardDidCopyAutomatically() {
        sensitivePasteboardHasPendingAutoClear = sensitivePasteboard.hasPendingAutoClear
        if sensitivePasteboard.hasPendingAutoClear {
            startSensitivePasteboardExpiryMonitor()
        } else {
            sensitivePasteboardExpiryTask?.cancel()
            sensitivePasteboardExpiryTask = nil
        }
    }

    @discardableResult
    func copySensitiveValueToPasteboard(_ secret: String) -> SensitivePasteboardCopyFeedback {
        let feedback = copySensitiveValueToPasteboardWithoutHaptics(secret)
        if feedback != .nothingToCopy {
            haptics.play(.success)
        }
        return feedback
    }

    func copySensitiveValueToPasteboardWithoutHaptics(_ secret: String) -> SensitivePasteboardCopyFeedback {
        switch sensitivePasteboard.copy(secret: secret, ttl: sensitiveClipboardTTL) {
        case .nothingToCopy:
            return .nothingToCopy
        case .copiedWithoutAutoClear:
            sensitivePasteboardHasPendingAutoClear = false
            sensitivePasteboardExpiryTask?.cancel()
            sensitivePasteboardExpiryTask = nil
            return .copiedWithoutAutoClear
        case .copiedWithAutoClear:
            sensitivePasteboardHasPendingAutoClear = true
            startSensitivePasteboardExpiryMonitor()
            return .copiedWithAutoClear(seconds: sensitiveClipboardTTL.rawValue)
        }
    }

    @discardableResult
    func checkSensitivePasteboardExpiry(at date: Date = Date()) -> MonicaSensitivePasteboard.ExpiryOutcome {
        let outcome = sensitivePasteboard.clearIfExpired(at: date)
        switch outcome {
        case .noPendingValue, .cleared, .skippedBecauseReplacedByAnotherApp:
            sensitivePasteboardHasPendingAutoClear = false
            sensitivePasteboardExpiryTask?.cancel()
            sensitivePasteboardExpiryTask = nil
        case .notYetDue:
            sensitivePasteboardHasPendingAutoClear = true
        }
        return outcome
    }

    @discardableResult
    func clearSensitivePasteboardManually() -> MonicaSensitivePasteboard.ExpiryOutcome {
        let outcome = sensitivePasteboard.clearImmediatelyIfOwned()
        sensitivePasteboardHasPendingAutoClear = sensitivePasteboard.hasPendingAutoClear
        if !sensitivePasteboard.hasPendingAutoClear {
            sensitivePasteboardExpiryTask?.cancel()
            sensitivePasteboardExpiryTask = nil
        }
        return outcome
    }

    /// 回到前台时补做到期检查：App 被挂起期间 Timer 不会运行，系统也不允许可靠的秒级后台清理。
    func resumeSensitivePasteboardExpiryMonitoringIfNeeded() {
        guard sensitivePasteboard.hasPendingAutoClear else {
            sensitivePasteboardHasPendingAutoClear = false
            sensitivePasteboardExpiryTask?.cancel()
            sensitivePasteboardExpiryTask = nil
            return
        }
        _ = checkSensitivePasteboardExpiry()
        if sensitivePasteboard.hasPendingAutoClear {
            startSensitivePasteboardExpiryMonitor()
        }
    }

    func startSensitivePasteboardExpiryMonitor() {
        sensitivePasteboardExpiryTask?.cancel()
        guard sensitivePasteboard.hasPendingAutoClear else {
            sensitivePasteboardHasPendingAutoClear = false
            return
        }
        sensitivePasteboardExpiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else {
                    return
                }
                self.checkSensitivePasteboardExpiry()
                if !self.sensitivePasteboard.hasPendingAutoClear {
                    return
                }
            }
        }
    }
}
