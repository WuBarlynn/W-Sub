import AppKit
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

if variant == "renew" {
    let center = CGPoint(x: canvas / 2, y: 430)
    let radius: CGFloat = 132
    let lineWidth: CGFloat = 48
    let halfWidth = lineWidth / 2

    func radians(_ degrees: CGFloat) -> CGFloat { degrees * CGFloat.pi / 180 }
    func point(_ angle: CGFloat, _ r: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
    }

    // 缺口在右下角：尾巴在右侧（斜切），箭头在正下方
    let baseAngle = radians(-88)
    let tailAngle = radians(-2)
    let chisel = radians(6)
    let tipAngle = baseAngle + radians(34)

    let outerStart = tailAngle + chisel
    let innerEnd = tailAngle - chisel

    // 以缺口中心（-45°）为轴做镜像：缺口还留在右下角，箭头方向反过来
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: radians(-45))
    ctx.scaleBy(x: 1, y: -1)
    ctx.rotate(by: radians(45))
    ctx.translateBy(x: -center.x, y: -center.y)

    // 环身：上沿从斜切口逆时针绕到箭头根部，再沿内沿绕回
    let ring = CGMutablePath()
    ring.move(to: point(innerEnd, radius - halfWidth))
    ring.addLine(to: point(outerStart, radius + halfWidth))
    ring.addArc(center: center, radius: radius + halfWidth,
                startAngle: outerStart, endAngle: baseAngle + radians(5) + 2 * CGFloat.pi, clockwise: false)
    ring.addLine(to: point(baseAngle + radians(5), radius - halfWidth))
    ring.addArc(center: center, radius: radius - halfWidth,
                startAngle: baseAngle + radians(5), endAngle: innerEnd, clockwise: true)
    ring.closeSubpath()
    ctx.setFillColor(brand)
    ctx.addPath(ring)
    ctx.fillPath()

    // 箭头单独画，底边比环身宽一点，才是「箭头」而不是尖角
    let headHalf = halfWidth + 12
    let head = CGMutablePath()
    head.move(to: point(baseAngle, radius + headHalf))
    head.addLine(to: point(tipAngle, radius))
    head.addLine(to: point(baseAngle, radius - headHalf))
    head.closeSubpath()
    ctx.addPath(head)
    ctx.fillPath()

    ctx.restoreGState()
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
