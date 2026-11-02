#if os(iOS)
import SwiftUI
import UIKit
import WSCore

// MARK: - 图标资源

enum BrandAssets {
    static func has(_ name: String) -> Bool {
        UIImage(named: name, in: .module, compatibleWith: nil) != nil
    }
}

/// 统一的图标容器：品牌标 → 自定义图 → SF Symbol → 首字母。
public struct IconTile: View {
    private let brand: String?
    private let symbol: String
    private let hex: String
    private let name: String
    private let customID: UUID?
    private let size: CGFloat

    public init(brand: String?, symbol: String, hex: String, name: String,
                customID: UUID? = nil, size: CGFloat = 44) {
        self.brand = brand
        self.symbol = symbol
        self.hex = hex
        self.name = name
        self.customID = customID
        self.size = size
    }

    private var tint: Color { Color(hex: hex) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: size * 0.30, style: .continuous) }
    private var isFullColor: Bool { BrandCatalog.style(for: brand) == "color" }

    public var body: some View {
        ZStack {
            // 底色始终铺品牌色：全彩图自带留白时不会露出白缝
            shape.fill(tint)
            if let customID, let image = IconStore.shared.image(id: customID) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else if let brand, BrandAssets.has(brand) {
                if isFullColor {
                    // 源图已规整为正方形画布，等比铺满不会裁掉任何内容
                    Image(brand, bundle: .module)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipped()
                        .clipShape(shape)
                } else {
                    Image(brand, bundle: .module)
                        .resizable()
                        .scaledToFit()
                        .padding(size * 0.22)
                        .frame(width: size, height: size)
                }
            } else if !symbol.isEmpty, UIImage(systemName: symbol) != nil {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.40, weight: .medium))
                    .foregroundStyle(.white)
            } else {
                Text(monogram)
                    .font(.system(size: size * 0.40, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }

    private var monogram: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "·" }
        return String(first).uppercased()
    }
}

public extension Subscription {
    var iconBrand: String? { brandID }
    var iconSymbol: String { symbolName }
}

// MARK: - 自定义图标存储

/// 用户上传/在线下载的图标以 PNG 存在 Application Support/Icons。
/// 图标本身不含隐私信息，但为了保持「数据只在一个文件里」的心智，设置页提供一键清理。
public final class IconStore: @unchecked Sendable {
    public static let shared = IconStore()

    private let directory: URL
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func save(_ image: UIImage, id: UUID = UUID()) -> UUID? {
        let square = image.squareImage(side: 256)
        guard let data = square.pngData() else { return nil }
        do {
            try data.write(to: url(for: id), options: .atomic)
            cache.setObject(square, forKey: id.uuidString as NSString)
            return id
        } catch {
            return nil
        }
    }

    public func image(id: UUID) -> UIImage? {
        if let hit = cache.object(forKey: id.uuidString as NSString) { return hit }
        guard let image = UIImage(contentsOfFile: url(for: id).path) else { return nil }
        cache.setObject(image, forKey: id.uuidString as NSString)
        return image
    }

    public func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
        cache.removeObject(forKey: id.uuidString as NSString)
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache.removeAllObjects()
    }

    public func count() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).png")
    }
}

extension UIImage {
    func squareImage(side: CGFloat) -> UIImage {
        let target = CGSize(width: side, height: side)
        let scale = max(side / size.width, side / size.height)
        let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}

// MARK: - 在线图标

public struct RemoteIcon: Identifiable, Hashable, Sendable {
    public let id: String

    public init(id: String) { self.id = id }

    public var prefix: String {
        String(id.split(separator: ":", maxSplits: 1).first ?? "")
    }

    public var name: String {
        let parts = id.split(separator: ":", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : id
    }
}

/// 只在你主动搜索时才发请求；不写日志、不自动上报。
public actor IconSearchService {
    public static let shared = IconSearchService()

    private var cache: [String: UIImage] = [:]
    private var lastQuery: String = ""

    public func search(_ query: String, limit: Int = 30) async throws -> [RemoteIcon] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        var components = URLComponents(string: "https://api.iconify.design/search")
        components?.queryItems = [
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        let payload = try JSONDecoder().decode(SearchPayload.self, from: data)
        lastQuery = trimmed
        return payload.icons.map(RemoteIcon.init)
    }

    public func image(for icon: RemoteIcon, size: CGFloat = 96) async -> UIImage? {
        if let hit = cache[icon.id] { return hit }
        guard let url = URL(string: "https://api.iconify.design/\(icon.prefix)/\(icon.name).svg") else {
            return nil
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let image = SVGRenderer.image(from: data, size: CGSize(width: size, height: size)) else {
                return nil
            }
            cache[icon.id] = image
            return image
        } catch {
            return nil
        }
    }

    private struct SearchPayload: Decodable {
        var icons: [String]
    }
}

// MARK: - 本地图标目录（内置品牌）

public struct BrandOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let hex: String
    public let tile: String
    public let style: String
    public let category: String
}

public enum BrandCatalog {
    public static let all: [BrandOption] = TemplateCatalog.all.compactMap { template in
        guard let brand = template.brand, BrandAssets.has(brand) else { return nil }
        return BrandOption(id: brand, name: template.name, hex: template.hex,
                           tile: template.tile, style: template.style, category: template.categoryID)
    }

    private static let styles: [String: String] = Dictionary(
        all.map { ($0.id, $0.style) },
        uniquingKeysWith: { first, _ in first }
    )

    public static func style(for brand: String?) -> String {
        guard let brand else { return "mono" }
        return styles[brand] ?? "mono"
    }

    public static func search(_ query: String) -> [BrandOption] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(trimmed) || $0.id.contains(trimmed) }
    }
}
#endif
