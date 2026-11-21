import SwiftUI
import WidgetKit

@main
struct MonicaWidgetBundle: WidgetBundle {
    var body: some Widget {
        MonicaOpenPageControl()
        MonicaWidget()
        // Issue #47：用户手动开始/结束的验证器锁屏倒计时。
        MonicaAuthenticatorLiveActivityWidget()
    }
}
