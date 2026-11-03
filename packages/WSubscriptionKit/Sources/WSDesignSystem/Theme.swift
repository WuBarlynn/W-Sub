import SwiftUI

/// 设计令牌：内容优先、纸面化。玻璃只留给系统 chrome（标签栏、导航栏、菜单、表单）。
public enum WSTheme {
    public static let pagePadding: CGFloat = 20
    public static let cardRadius: CGFloat = 20
    public static let innerRadius: CGFloat = 14
    public static let accent = Color(hex: "#2C46C7")

    public static let titleSize: CGFloat = 17
    public static let bodySize: CGFloat = 15
    public static let metaSize: CGFloat = 13
    public static let sectionSize: CGFloat = 13
}

public extension Color {
    init(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        var rgb: UInt64 = 0
        Scanner(string: value).scanHexInt64(&rgb)
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: 1
        )
    }

    static var wsPage: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.gray.opacity(0.1)
        #endif
    }

    static var wsCard: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.white
        #endif
    }

    static var wsHairline: Color {
        #if canImport(UIKit)
        Color(uiColor: .separator).opacity(0.5)
        #else
        Color.gray.opacity(0.2)
        #endif
    }

    static var wsSecondaryText: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondaryLabel)
        #else
        Color.secondary
        #endif
    }
}

public extension Font {
    /// 金额、日期这类需要对齐的数字统一用等宽数字，视觉上更稳。
    static func wsNumber(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    static var wsTitle: Font { .system(size: WSTheme.titleSize, weight: .semibold) }
    static var wsBody: Font { .system(size: WSTheme.bodySize, weight: .regular) }
    static var wsMeta: Font { .system(size: WSTheme.metaSize, weight: .regular) }
}

// MARK: - 基本容器

public struct SurfaceCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.wsCard, in: RoundedRectangle(cornerRadius: WSTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WSTheme.cardRadius, style: .continuous)
                    .strokeBorder(Color.wsHairline, lineWidth: 0.5)
            }
    }
}

public struct WSSectionTitle: View {
    private let text: String
    private let trailing: String?

    public init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.system(size: WSTheme.sectionSize, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}

public struct WSRowDivider: View {
    private let inset: CGFloat
    public init(inset: CGFloat = 0) { self.inset = inset }

    public var body: some View {
        Rectangle()
            .fill(Color.wsHairline)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

public struct WSTag: View {
    private let text: String
    private let tint: Color

    public init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

public struct WSEmptyState: View {
    private let symbol: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(symbol: String, title: String, message: String,
                actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.wsTitle)
            Text(message)
                .font(.wsMeta)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
    }
}

/// 列表/设置里的行按钮按压反馈：按下轻微缩放 + 变暗，松手回弹。
/// 用于替代 `.buttonStyle(.plain)`（plain 没有按压反馈）。
public struct WSPressButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
