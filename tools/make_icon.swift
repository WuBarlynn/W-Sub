import AppKit
import CoreText
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 生成 App 图标：纯色底 + 一叠订阅卡片。
/// 一叠卡片 = 好几项订阅摞在一起，对应 App 首页那套翻页卡片；
/// 最前面一张上放一个顺时针的循环箭头，说明这些是「会周期性扣钱的」。
/// 用法：swift make_icon.swift <输出路径> [stack|renew]

let args = CommandLine.arguments
let outputPath = args.count > 1 ? args[1] : "icon-1024.png"
let variant = args.count > 2 ? args[2] : "renew"

let side = 1024
let canvas = CGFloat(side)
let space = CGColorSpaceCreateDeviceRGB()

let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

let brand = color(CGFloat(44) / 255, CGFloat(70) / 255, CGFloat(199) / 255)

// 底色：单色，无渐变
ctx.setFillColor(brand)
ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))

let cardWidth: CGFloat = 720
let cardHeight: CGFloat = 440
let cardRadius: CGFloat = 68

/// 一张居中、可缩放的圆角卡片。CoreGraphics 的 y 向上为正，所以 centerY 越大越靠上。
func drawCard(centerY: CGFloat, scale: CGFloat, alpha: CGFloat) {
    let width = cardWidth * scale
    let height = cardHeight * scale
    let rect = CGRect(x: (canvas - width) / 2, y: centerY - height / 2, width: width, height: height)
    ctx.setFillColor(color(1, 1, 1, alpha))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: cardRadius * scale,
                       cornerHeight: cardRadius * scale, transform: nil))
    ctx.fillPath()
}

// 后面的卡往上露头，最前面一张压在最下面 —— 像一叠卡片从正面看过去
drawCard(centerY: 622, scale: 0.86, alpha: 0.34)
drawCard(centerY: 526, scale: 0.93, alpha: 0.60)
drawCard(centerY: 430, scale: 1.00, alpha: 1.00)

if variant == "renew" || variant == "w" {
    // 前面那张卡中间放一个 W：SF Rounded Heavy，用 CoreText 画真实的字形，
    // 比手掰折线稳，缩到 60pt 也不会散。
    let center = CGPoint(x: canvas / 2, y: 430)
    let base = NSFont.systemFont(ofSize: 430, weight: .heavy)
    let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    let font = NSFont(descriptor: descriptor, size: 430) ?? base

    let attributed = NSAttributedString(string: "W", attributes: [
        .font: font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): brand
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
    CTLineDraw(line, ctx)
}

guard let image = ctx.makeImage() else { exit(1) }
let url = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                       UTType.png.identifier as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("written: \(url.path)")
