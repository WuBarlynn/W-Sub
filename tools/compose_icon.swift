import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 把栅格化后的品牌图合成为 App 图标：
/// 1. 不透明占比 > 50% 视为「自带背景的完整图标」，直接铺满
/// 2. 否则视为纯 logo：铺品牌底色，logo 居中 64%
/// 3. 纯 logo 且本身很暗、底色也暗时，反白保证对比
/// 用法：compose_icon <in.png> <tileHex> <out.png>
let args = CommandLine.arguments
guard args.count >= 4 else { exit(1) }
let inPath = args[1], tileHex = args[2], outPath = args[3]
let logoScale = args.count >= 5 ? (CGFloat(Double(args[4]) ?? 0.64)) : 0.64

let side = 512
let space = CGColorSpaceCreateDeviceRGB()

func load(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func rgb(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
    var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
    var raw: UInt64 = 0
    Scanner(string: value).scanHexInt64(&raw)
    return (CGFloat((raw >> 16) & 0xFF) / 255,
            CGFloat((raw >> 8) & 0xFF) / 255,
            CGFloat(raw & 0xFF) / 255)
}

func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
    0.2126 * r + 0.7152 * g + 0.0722 * b
}

func write(_ image: CGImage, to path: String) {
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                           UTType.png.identifier as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

guard let source = load(inPath) else { exit(1) }

var buffer = [UInt8](repeating: 0, count: side * side * 4)
let probe = CGContext(data: &buffer, width: side, height: side, bitsPerComponent: 8,
                      bytesPerRow: side * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
probe.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))

var opaque = 0
var sumLum: CGFloat = 0
for index in stride(from: 0, to: buffer.count, by: 4) {
    let a = buffer[index + 3]
    if a > 32 {
        opaque += 1
        sumLum += luminance(CGFloat(buffer[index]) / 255,
                            CGFloat(buffer[index + 1]) / 255,
                            CGFloat(buffer[index + 2]) / 255)
    }
}
let ratio = CGFloat(opaque) / CGFloat(side * side)
let logoLum = opaque > 0 ? sumLum / CGFloat(opaque) : 1
let (tr, tg, tb) = rgb(tileHex)
let tileLum = luminance(tr, tg, tb)

let output = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                       bytesPerRow: 0, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
output.interpolationQuality = .high

if ratio > 0.5 {
    // 自带背景的完整图标：放大 8% 铺满，把原图自带的圆角挤到画布外，
    // 这样界面里只会看到我们自己的圆角，不会出现「双层圆角」
    let bleed = CGFloat(side) * 1.08
    let offset = (CGFloat(side) - bleed) / 2
    output.draw(source, in: CGRect(x: offset, y: offset, width: bleed, height: bleed))
} else {
    output.setFillColor(CGColor(colorSpace: space, components: [tr, tg, tb, 1])!)
    output.fill(CGRect(x: 0, y: 0, width: side, height: side))

    var drawable = source
    let needsInvert = logoLum < 0.42 && tileLum < 0.55
    let needsDarken = logoLum > 0.85 && tileLum > 0.82
    if needsInvert || needsDarken {
        for index in stride(from: 0, to: buffer.count, by: 4) {
            let a = buffer[index + 3]
            let value: UInt8 = needsInvert ? a : 0
            buffer[index] = value
            buffer[index + 1] = value
            buffer[index + 2] = value
        }
        if let provider = CGDataProvider(data: Data(buffer) as CFData),
           let inverted = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) {
            drawable = inverted
        }
    }

    let target = CGFloat(side) * logoScale
    let origin = (CGFloat(side) - target) / 2
    output.draw(drawable, in: CGRect(x: origin, y: origin, width: target, height: target))
}

guard let image = output.makeImage() else { exit(1) }
write(image, to: outPath)
