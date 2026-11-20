import Foundation
import MonicaCore
import UIKit

/// 系统剪贴板适配器。
///
/// 所有 `UIPasteboard` 访问都收敛在这里，由 `MonicaSensitivePasteboard`（MonicaCore）
/// 负责记录 `changeCount`、判断到期与是否仍是本 App 写入的值。
@MainActor
final class SystemSensitivePasteboard: SensitivePasteboardWriting {
    private let pasteboard: UIPasteboard

    init(pasteboard: UIPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// 读取变化计数不会触发 iOS 的粘贴隐私提示。
    var changeCount: Int {
        pasteboard.changeCount
    }

    var string: String? {
        pasteboard.string
    }

    func setString(_ value: String) {
        pasteboard.string = value
    }

    func clear() {
        // 置空 items 会移除所有条目（包括其它表示类型）；调用前由策略确认剪贴板仍是本 App 写入的值。
        pasteboard.items = []
    }
}

/// 一次复制操作给用户的反馈。只在内存里生成文案，不包含被复制的值。
enum SensitivePasteboardCopyFeedback: Equatable {
    case copiedWithAutoClear(seconds: Int)
    case copiedWithoutAutoClear
    case nothingToCopy

    var message: String {
        switch self {
        case .copiedWithAutoClear(let seconds):
            return String(localized: "已复制，\(seconds) 秒后尝试清除剪贴板")
        case .copiedWithoutAutoClear:
            return String(localized: "已复制")
        case .nothingToCopy:
            return String(localized: "没有可复制的内容")
        }
    }
}

extension SensitivePreviewCategory {
    /// 设置页里的类别名称。
    var localizedTitle: String {
        switch self {
        case .password:
            return String(localized: "密码")
        case .totp:
            return String(localized: "验证码")
        case .cardNumber:
            return String(localized: "银行卡号")
        case .cvv:
            return String(localized: "安全码 CVV")
        case .noteBody:
            return String(localized: "笔记正文")
        case .otherSecret:
            return String(localized: "其它敏感字段")
        }
    }

    /// 设置页里的一句话说明。
    var localizedDetail: String {
        switch self {
        case .password:
            return String(localized: "登录密码与 Wi-Fi 密码")
        case .totp:
            return String(localized: "动态验证码与 TOTP 密钥")
        case .cardNumber:
            return String(localized: "银行卡号完整数字")
        case .cvv:
            return String(localized: "银行卡背面的安全码")
        case .noteBody:
            return String(localized: "笔记与 Send 的正文预览")
        case .otherSecret:
            return String(localized: "证件号、API Token、私钥引用等")
        }
    }
}
