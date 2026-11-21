import SwiftUI

/// iOS 26 Liquid Glass 原生材质适配层（issue #78）。
///
/// 设计约束：
/// - 最低支持 iOS 17，所以所有 iOS 26 专属 API 都只出现在本文件的 `#available(iOS 26.0, *)` 分支里；
///   业务视图统一调用下面的修饰符，不再各自判断系统版本（`AppLiquidGlassSupportTests` 用源码扫描守住这条约束）。
/// - 品牌色板不做替换：玻璃只负责材质，颜色仍然来自 `AndroidParityPalette`。
/// - 用户开启「降低透明度」或「增强对比度」时退化到不透明表面，玻璃不承载唯一的信息层级。
/// - 只为真正自绘的浮动控件（FAB、页头动作胶囊）使用玻璃；内容卡片保持不透明表面，避免玻璃叠玻璃。
enum AppLiquidGlass {
    /// 自绘浮动控件的表面材质。
    enum SurfaceMaterial: Equatable {
        /// iOS 26 原生液态玻璃。
        case liquidGlass
        /// 主题不透明表面：iOS 17–25，或用户要求降低透明度。
        case opaqueSurface
    }

    /// 浮动控件的表面样式，纯数据以便单元测试穷举。
    struct FloatingSurfaceStyle: Equatable {
        /// 是否使用系统液态玻璃。
        let material: SurfaceMaterial
        /// 不透明分支下的描边宽度；玻璃自带高光描边，不需要额外叠加。
        let opaqueOutlineWidth: CGFloat

        var usesGlass: Bool { material == .liquidGlass }
    }

    /// 当前系统是否提供 Liquid Glass 材质。
    static var isAvailable: Bool {
        if #available(iOS 26.0, *) {
            return true
        } else {
            return false
        }
    }

    /// 依据系统能力与可访问性偏好选择浮动控件表面。
    ///
    /// 规则：只有「系统支持玻璃」且「用户没有要求降低透明度」时才用玻璃，
    /// 其余情况一律退化为不透明主题表面；增强对比度时加深不透明分支的描边。
    static func floatingSurface(
        isAvailable: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> FloatingSurfaceStyle {
        // 只在用户明确要求增强对比度时加描边：默认外观必须与 iOS 17–25 的现有观感一致。
        let outlineWidth: CGFloat = increaseContrast ? 1.5 : 0
        guard isAvailable, !reduceTransparency else {
            return FloatingSurfaceStyle(material: .opaqueSurface, opaqueOutlineWidth: outlineWidth)
        }
        return FloatingSurfaceStyle(material: .liquidGlass, opaqueOutlineWidth: 0)
    }
}

// MARK: - 修饰符

extension View {
    /// 根标签栏材质。
    ///
    /// iOS 26 的系统标签栏本身就是液态玻璃，这里只声明交互策略：issue #78 决策 4 要求
    /// 四个 Tab 常驻，不随滚动自动收起。iOS 17–25 无需任何处理，保持现状。
    func appLiquidGlassTabBar() -> some View {
        modifier(AppTabBarMaterialModifier())
    }

    /// 导航栏材质。
    ///
    /// iOS 17–25 维持原有的实色底且常显；iOS 26 不再强制不透明底色，
    /// 让系统玻璃与滚动边缘渐隐效果生效（否则会盖死材质并产生「人造」色带）。
    func appNavigationBarMaterial(fallbackFill: Color) -> some View {
        modifier(AppNavigationBarMaterialModifier(fallbackFill: fallbackFill))
    }

    /// 自绘浮动控件表面：可用且不降低透明度时用玻璃，否则用主题不透明底色 + 描边。
    func appFloatingControlSurface<SurfaceShape: Shape>(
        fill: Color,
        outline: Color,
        shape: SurfaceShape
    ) -> some View {
        modifier(AppFloatingControlSurfaceModifier(fill: fill, outline: outline, shape: shape))
    }

    /// 滚动容器底部边缘效果：让内容在 iOS 26 的浮动标签栏下方渐隐，而不是被硬切一条。
    func appScrollEdgeEffectBottom() -> some View {
        modifier(AppScrollEdgeEffectBottomModifier())
    }
}

private struct AppTabBarMaterialModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.never)
        } else {
            content
        }
    }
}

private struct AppNavigationBarMaterialModifier: ViewModifier {
    let fallbackFill: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // 系统导航栏已是玻璃材质，再铺底色会遮挡材质并让滚动边缘效果失效。
            content
        } else {
            content
                .toolbarBackground(fallbackFill, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

private struct AppFloatingControlSurfaceModifier<SurfaceShape: Shape>: ViewModifier {
    let fill: Color
    let outline: Color
    let shape: SurfaceShape

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let style = AppLiquidGlass.floatingSurface(
            isAvailable: AppLiquidGlass.isAvailable,
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased
        )
        if #available(iOS 26.0, *), style.usesGlass {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(fill, in: shape)
                .overlay {
                    if style.opaqueOutlineWidth > 0 {
                        shape.stroke(outline, lineWidth: style.opaqueOutlineWidth)
                    }
                }
        }
    }
}

private struct AppScrollEdgeEffectBottomModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content
        }
    }
}
