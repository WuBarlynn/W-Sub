import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let canvas = CGFloat(size)
let space = CGColorSpaceCreateDeviceRGB()
let white = CGColor(colorSpace: space, components: [1, 1, 1, 1])!

let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// 纯色底：无渐变、无描边
ctx.setFillColor(CGColor(colorSpace: space, components: [CGFloat(44) / 255, CGFloat(70) / 255, CGFloat(199) / 255, 1])!)
ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))

// 几何 W：四段折线，圆角接头，纯白实心
let w = CGMutablePath()
w.move(to: CGPoint(x: 214, y: 668))
w.addLine(to: CGPoint(x: 352, y: 356))
w.addLine(to: CGPoint(x: 512, y: 612))
w.addLine(to: CGPoint(x: 672, y: 356))
w.addLine(to: CGPoint(x: 810, y: 668))

ctx.setStrokeColor(white)
ctx.setLineWidth(112)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.addPath(w)
ctx.strokePath()

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("written: \(url.path)")
