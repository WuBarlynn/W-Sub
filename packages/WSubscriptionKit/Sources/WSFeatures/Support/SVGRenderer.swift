#if os(iOS)
import UIKit

/// 极简 SVG 渲染器：只处理 Iconify 品牌图里实际出现的图形（path / circle / rect / g）。
/// 目的很单一 —— 让「在线搜索图标」能把 SVG 变成可缓存的位图，不追求完整 SVG 规范。
enum SVGRenderer {

    static func image(from data: Data, size: CGSize) -> UIImage? {
        guard let document = SVGDocument(data: data), document.viewBox.width > 0, document.viewBox.height > 0 else {
            return nil
        }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let cg = context.cgContext
            let box = document.viewBox
            let scale = min(size.width / box.width, size.height / box.height)
            cg.translateBy(x: (size.width - box.width * scale) / 2,
                           y: (size.height - box.height * scale) / 2)
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -box.minX, y: -box.minY)
            document.draw(in: cg)
        }
    }
}

// MARK: - 文档

private struct SVGNode {
    var name: String
    var attributes: [String: String]
    var children: [SVGNode] = []
}

private final class SVGDocument: NSObject, XMLParserDelegate {
    private(set) var viewBox = CGRect(x: 0, y: 0, width: 24, height: 24)
    private var root: SVGNode?
    private var stack: [SVGNode] = []
    private var depth = 0

    init?(data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), let root else { return nil }
        self.root = root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "svg" {
            if let raw = attributeDict["viewBox"] {
                let parts = raw.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
                if parts.count == 4 {
                    viewBox = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                }
            } else if let w = Double(attributeDict["width"] ?? ""), let h = Double(attributeDict["height"] ?? "") {
                viewBox = CGRect(x: 0, y: 0, width: w, height: h)
            }
        }
        let node = SVGNode(name: elementName, attributes: attributeDict)
        if depth == 0 {
            root = node
        } else if !stack.isEmpty {
            stack[stack.count - 1].children.append(node)
        }
        stack.append(node)
        depth += 1
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
        depth = max(0, depth - 1)
    }

    func draw(in context: CGContext) {
        guard let root else { return }
        for child in root.children {
            draw(node: child, in: context, inheritedFill: UIColor.black, inheritedRule: .winding)
        }
    }

    private func draw(node: SVGNode, in context: CGContext, inheritedFill: UIColor, inheritedRule: CGPathFillRule) {
        let fill = resolveFill(node.attributes["fill"]) ?? inheritedFill
        let rule = (node.attributes["fill-rule"] == "evenodd") ? CGPathFillRule.evenOdd : inheritedRule
        let opacity = Double(node.attributes["opacity"] ?? "") ?? 1

        if node.name == "g" {
            for child in node.children {
                draw(node: child, in: context, inheritedFill: fill, inheritedRule: rule)
            }
            return
        }

        if node.attributes["fill"] == "none" { return }

        var path: CGPath?
        switch node.name {
        case "path":
            if let d = node.attributes["d"] {
                path = SVGPathParser.path(from: d)
            }
        case "circle":
            if let cx = number(node, "cx"), let cy = number(node, "cy"), let r = number(node, "r") {
                path = CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2), transform: nil)
            }
        case "rect":
            if let x = number(node, "x"), let y = number(node, "y"),
               let w = number(node, "width"), let h = number(node, "height") {
                let radius = number(node, "rx") ?? 0
                path = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
                              cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
        case "ellipse":
            if let cx = number(node, "cx"), let cy = number(node, "cy"),
               let rx = number(node, "rx"), let ry = number(node, "ry") {
                path = CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil)
            }
        default:
            break
        }

        guard let path else { return }
        context.saveGState()
        context.setFillColor(fill.withAlphaComponent(fill.cgColor.alpha * opacity).cgColor)
        context.addPath(path)
        context.fillPath(using: rule)
        context.restoreGState()
    }

    private func number(_ node: SVGNode, _ key: String) -> CGFloat? {
        guard let raw = node.attributes[key] else { return nil }
        return Double(raw.replacingOccurrences(of: "px", with: "")).map { CGFloat($0) }
    }

    private func resolveFill(_ raw: String?) -> UIColor? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw == "none" { return nil }
        if raw == "currentColor" { return .black }
        if raw.hasPrefix("#") {
            var hex = String(raw.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255,
                           alpha: 1)
        }
        if raw.hasPrefix("rgb") {
            let numbers = raw.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
            guard numbers.count >= 3 else { return nil }
            return UIColor(red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, alpha: 1)
        }
        return nil
    }
}

// MARK: - Path

enum SVGPathParser {
    static func path(from d: String) -> CGPath? {
        var scanner = Scanner(text: d)
        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var command: Character = "M"
        var hasDrawn = false

        loop: while true {
            if !scanner.skipSeparators() { break }
            if let letter = scanner.takeCommand() {
                command = letter
            } else if scanner.atEnd {
                break
            }

            let relative = command.isLowercase
            switch Character(command.uppercased()) {
            case "M":
                guard let p = scanner.point() else { break loop }
                let target = relative ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
                path.move(to: target)
                current = target
                subpathStart = target
                lastControl = nil
                command = relative ? "l" : "L"

            case "L":
                guard let p = scanner.point() else { break loop }
                let target = relative ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
                path.addLine(to: target)
                current = target
                lastControl = nil
                hasDrawn = true

            case "H":
                guard let x = scanner.number() else { break loop }
                let target = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: target)
                current = target
                lastControl = nil
                hasDrawn = true

            case "V":
                guard let y = scanner.number() else { break loop }
                let target = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: target)
                current = target
                lastControl = nil
                hasDrawn = true

            case "C":
                guard let c1 = scanner.point(), let c2 = scanner.point(), let p = scanner.point() else {
                    break loop
                }
                let a = relative ? CGPoint(x: current.x + c1.x, y: current.y + c1.y) : c1
                let b = relative ? CGPoint(x: current.x + c2.x, y: current.y + c2.y) : c2
                let end = relative ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
                path.addCurve(to: end, control1: a, control2: b)
                current = end
                lastControl = b
                hasDrawn = true

            case "S":
                guard let c2 = scanner.point(), let p = scanner.point() else { break loop }
                let reflected = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let b = relative ? CGPoint(x: current.x + c2.x, y: current.y + c2.y) : c2
                let end = relative ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
                path.addCurve(to: end, control1: reflected, control2: b)
                current = end
                lastControl = b
                hasDrawn = true

            case "Q":
                guard let c = scanner.point(), let p = scanner.point() else { break loop }
                let control = relative ? CGPoint(x: current.x + c.x, y: current.y + c.y) : c
                let end = relative ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
                path.addQuadCurve(to: end, control: control)
                current = end
                lastControl = control
                hasDrawn = true

            case "T":
                guard let p = scanner.point() else { break loop }
                let control = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let end = relative ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
                path.addQuadCurve(to: end, control: control)
                current = end
                lastControl = control
                hasDrawn = true

            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(),
                      let rotation = scanner.number(), let large = scanner.flag(),
                      let sweep = scanner.flag(), let p = scanner.point() else { break loop }
                let end = relative ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
                addArc(to: path, from: current, to: end, rx: rx, ry: ry,
                       rotation: rotation, large: large, sweep: sweep)
                current = end
                lastControl = nil
                hasDrawn = true

            case "Z":
                path.closeSubpath()
                current = subpathStart
                lastControl = nil

            default:
                break loop
            }
        }
        return hasDrawn ? path : nil
    }

    /// 圆形近似（图标里的圆角与圆环基本都是 rx == ry 且无旋转）。
    private static func addArc(to path: CGMutablePath, from start: CGPoint, to end: CGPoint,
                               rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        guard rx > 0, ry > 0 else {
            path.addLine(to: end)
            return
        }
        let radius = (rx + ry) / 2
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let chord = sqrt(dx * dx + dy * dy)
        guard chord > 0.0001, chord <= radius * 2 else {
            path.addLine(to: end)
            return
        }
        let h = sqrt(max(0, radius * radius - (chord / 2) * (chord / 2)))
        let normal = CGPoint(x: -dy / chord, y: dx / chord)
        let sign: CGFloat = (large == sweep) ? -1 : 1
        let center = CGPoint(x: mid.x + normal.x * h * sign, y: mid.y + normal.y * h * sign)
        let startAngle = atan2(start.y - center.y, start.x - center.x)
        let endAngle = atan2(end.y - center.y, end.x - center.x)
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: !sweep)
    }

    private struct Scanner {
        private let chars: [Character]
        private var index = 0

        init(text: String) { chars = Array(text) }

        var atEnd: Bool { index >= chars.count }

        mutating func takeCommand() -> Character? {
            guard index < chars.count, chars[index].isLetter else { return nil }
            let value = chars[index]
            index += 1
            return value
        }

        /// 返回是否还有内容可读
        mutating func skipSeparators() -> Bool {
            while index < chars.count {
                let character = chars[index]
                if character == " " || character == "," || character == "\n"
                    || character == "\t" || character == "\r" {
                    index += 1
                } else {
                    break
                }
            }
            return index < chars.count
        }

        mutating func number() -> CGFloat? {
            _ = skipSeparators()
            var text = ""
            if index < chars.count, chars[index] == "-" || chars[index] == "+" {
                text.append(chars[index])
                index += 1
            }
            var seenDot = false
            while index < chars.count {
                let character = chars[index]
                if character.isNumber {
                    text.append(character)
                    index += 1
                } else if character == ".", !seenDot {
                    seenDot = true
                    text.append(character)
                    index += 1
                } else if character == "e" || character == "E" {
                    text.append(character)
                    index += 1
                    if index < chars.count, chars[index] == "-" || chars[index] == "+" {
                        text.append(chars[index])
                        index += 1
                    }
                } else {
                    break
                }
            }
            return Double(text).map { CGFloat($0) }
        }

        mutating func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }

        mutating func flag() -> Bool? {
            _ = skipSeparators()
            guard index < chars.count else { return nil }
            let character = chars[index]
            guard character == "0" || character == "1" else { return nil }
            index += 1
            return character == "1"
        }
    }
}
#endif
