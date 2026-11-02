#if os(iOS)
import SwiftUI
import WSCore

/// 页面底板：实色分组背景。没有渐变、没有光斑，滚动时不会出现突兀的色带。
public struct Screen<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.wsPage)
    }
}

public struct ShakeEffect: GeometryEffect {
    public var animatableData: CGFloat
    public var amplitude: CGFloat = 9
    public var shakesPerUnit: CGFloat = 3

    public init(animatableData: CGFloat) {
        self.animatableData = animatableData
    }

    public func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amplitude * sin(animatableData * .pi * shakesPerUnit * 2),
                                              y: 0))
    }
}

public struct InlineNotice: View {
    private let text: String
    private let isError: Bool

    public init(_ text: String, isError: Bool = true) {
        self.text = text
        self.isError = isError
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isError ? Color(hex: "#C4320A") : Color.wsSecondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isError ? Color(hex: "#FFE9E3") : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

public extension Appearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public struct TabBarMinimizeModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
#endif
