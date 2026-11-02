#if os(iOS)
import SwiftUI
import PhotosUI
import WSDesignSystem
import WSCore

/// 三种图标来源：内置品牌库（离线）、在线搜索（Iconify）、相册上传。
struct IconPickerView: View {
    let currentBrand: String?
    let currentCustom: UUID?
    let onSelect: (String?, UUID?) -> Void

    @Environment(\.dismiss) private var dismiss

    enum Source: String, CaseIterable, Identifiable {
        case builtIn = "内置"
        case online = "在线"
        case photo = "相册"
        var id: String { rawValue }
    }

    @State private var source: Source = .builtIn
    @State private var query = ""
    @State private var remoteResults: [RemoteIcon] = []
    @State private var thumbs: [String: UIImage] = [:]
    @State private var isSearching = false
    @State private var isDownloading: String?
    @State private var errorText: String?
    @State private var photoItem: PhotosPickerItem?

    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("来源", selection: $source) {
                    ForEach(Source.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, WSTheme.pagePadding)
                .padding(.vertical, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch source {
                        case .builtIn: builtInGrid
                        case .online: onlineSection
                        case .photo: photoSection
                        }
                        if let errorText {
                            Text(errorText)
                                .font(.system(size: 12))
                                .foregroundStyle(Color(hex: "#C4320A"))
                        }
                    }
                    .padding(.horizontal, WSTheme.pagePadding)
                    .padding(.bottom, 24)
                }
            }
            .background(Color.wsPage)
            .navigationTitle("选择图标")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: source == .online ? "搜索任意品牌，例如 notion、iqiyi" : "搜索内置品牌")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task(id: "\(source.rawValue)|\(query)") {
                guard source == .online else { return }
                await runSearch()
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await importPhoto(item) }
            }
        }
    }

    // MARK: 内置

    private var builtInGrid: some View {
        let results = BrandCatalog.search(query)
        return VStack(alignment: .leading, spacing: 10) {
            WSSectionTitle("内置品牌", trailing: "\(results.count) 个")
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(results) { option in
                    Button {
                        onSelect(option.id, nil)
                        dismiss()
                    } label: {
                        VStack(spacing: 6) {
                            IconTile(brand: option.id, symbol: "", hex: option.tile, name: option.name, size: 50)
                            Text(option.name)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.wsCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(currentBrand == option.id ? WSTheme.accent : Color.wsHairline,
                                              lineWidth: currentBrand == option.id ? 1.5 : 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 在线

    private var onlineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "wifi")
                    .font(.system(size: 10))
                Text("图标来自 Iconify 开源图标库，仅在搜索时联网")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if isSearching && remoteResults.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("搜索中…").font(.wsMeta).foregroundStyle(.secondary)
                }
                .padding(.vertical, 20)
            } else if remoteResults.isEmpty {
                WSEmptyState(symbol: "magnifyingglass",
                             title: "输入关键词搜索",
                             message: "例如 netflix、spotify、银行")
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(remoteResults) { icon in
                        Button {
                            Task { await download(icon) }
                        } label: {
                            VStack(spacing: 5) {
                                RemoteIconThumb(icon: icon,
                                                image: thumbs[icon.id],
                                                isLoading: isDownloading == icon.id)
                                Text(icon.name)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(Color.wsCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.wsHairline, lineWidth: 0.5)
                            }
                        }
                        .buttonStyle(.plain)
                        .task {
                            guard thumbs[icon.id] == nil else { return }
                            if let image = await IconSearchService.shared.image(for: icon, size: 96) {
                                thumbs[icon.id] = image
                            }
                        }
                    }
                }
            }
        }
    }

    private func runSearch() async {
        guard source == .online else { return }
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard keyword.count >= 2 else {
            remoteResults = []
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let results = try await IconSearchService.shared.search(keyword)
            guard !Task.isCancelled else { return }
            remoteResults = results
            errorText = results.isEmpty ? "没有找到相关图标，换个关键词试试" : nil
        } catch {
            errorText = "搜索失败，请检查网络连接"
            remoteResults = []
        }
    }

    private func download(_ icon: RemoteIcon) async {
        isDownloading = icon.id
        defer { isDownloading = nil }
        guard let image = await IconSearchService.shared.image(for: icon, size: 256),
              let id = IconStore.shared.save(image) else {
            errorText = "这个图标暂时无法下载"
            return
        }
        onSelect(nil, id)
        dismiss()
    }

    // MARK: 相册

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从相册选一张图，会自动裁成方形并压缩到 256×256。图标只存在本机。")
                .font(.wsMeta)
                .foregroundStyle(.secondary)

            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text("从相册选择")
                        .font(.system(size: 15, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))

            if let currentCustom, let image = IconStore.shared.image(id: currentCustom) {
                HStack(spacing: 10) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text("当前使用的自定义图标")
                        .font(.wsMeta)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let id = IconStore.shared.save(image) else {
                errorText = "读取图片失败"
                return
            }
            onSelect(nil, id)
            dismiss()
        } catch {
            errorText = "读取图片失败"
        }
    }
}

private struct RemoteIconThumb: View {
    let icon: RemoteIcon
    let image: UIImage?
    let isLoading: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(9)
            } else if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "square.dashed")
                    .font(.system(size: 16))
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(width: 50, height: 50)
    }
}
#endif
