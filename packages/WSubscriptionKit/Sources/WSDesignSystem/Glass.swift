import SwiftUI

// 只保留系统 chrome 用的玻璃能力：标签栏 / 导航栏 / 菜单 / 弹出层由系统自动处理，
// 内容区一律用实色纸面，避免玻璃叠玻璃造成的低对比与色带。

// 用 compiler 版本做代理判断：iOS 26 SDK 随 Swift 6.2 一起发布，
// 这样在 Xcode 16（无 iOS 26 SDK）上会走材质降级，不会编译失败。
#if os(iOS) && compiler(>=6.2)
@available(iOS 26.0, *)
private func wsGlassValue(tint: Color?, interactive: Bool) -> Glass {
    var value: Glass = .regular
    if let tint { value = value.tint(tint) }
    if interactive { value = value.interactive() }
    return value
}
#endif

private struct WSFallbackGlass: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    Capsule(style: .continuous).fill(scheme == .dark ? Color(white: 0.16) : Color.white)
                } else {
                    Capsule(style: .continuous).fill(.regularMaterial)
                }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.wsHairline, lineWidth: 0.5)
            }
    }
}

public extension View {
    @ViewBuilder
    func wsGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        #if os(iOS) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(wsGlassValue(tint: tint, interactive: interactive), in: .capsule)
        } else {
            self.modifier(WSFallbackGlass())
        }
        #else
        self.modifier(WSFallbackGlass())
        #endif
    }
}
