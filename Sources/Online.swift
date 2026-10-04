import AppKit
import SwiftUI

// MARK: - Model

enum OnlineSource: String, CaseIterable, Identifiable {
    case wallhaven, bing
    var id: String { rawValue }
    var label: String { self == .wallhaven ? "Wallhaven" : "Bing Image of the Day" }
}

enum WallhavenSorting: String, CaseIterable, Identifiable {
    case toplist, hot, date_added, random, views, favorites
    var id: String { rawValue }
    var label: String {
        switch self {
        case .toplist: "Top"
        case .hot: "Hot"
        case .date_added: "Latest"
        case .random: "Random"
        case .views: "Most viewed"
        case .favorites: "Most favorited"
        }
    }
}

struct OnlineImage: Identifiable, Hashable {
    let id: String
    let thumb: URL
    let full: URL
    let title: String
    let detail: String
    let fileName: String
}

enum DownloadState: Equatable {
    case running, done(URL), failed(String)
}

final class OnlineModel: ObservableObject {
    @Published var source: OnlineSource = .wallhaven { didSet { search() } }
    @Published var query = ""
    @Published var sorting: WallhavenSorting = .toplist { didSet { search() } }
    @Published var results: [OnlineImage] = []
    @Published var loading = false
    @Published var error: String?
    @Published var downloads: [String: DownloadState] = [:]
    private var page = 1
    private var lastPage = 1

    /// Called with the saved file after a download that should be applied.
    var onApply: ((URL) -> Void)?
    var onDownloaded: (() -> Void)?

    var canLoadMore: Bool { source == .wallhaven && page < lastPage && !loading }

    func search(more: Bool = false) {
        if !more { page = 1; results = [] } else { page += 1 }
        loading = true
        error = nil
        let source = source, page = page, query = query, sorting = sorting
        Task {
            do {
                let (items, last) = try await source == .wallhaven
                    ? Self.wallhaven(query: query, sorting: sorting, page: page)
                    : Self.bing()
                await MainActor.run {
                    self.results += items.filter { item in !self.results.contains { $0.id == item.id } }
                    self.lastPage = last
                    self.loading = false
                }
            } catch {
                await MainActor.run {
                    self.error = "Could not load wallpapers: \(error.localizedDescription)"
                    self.loading = false
                }
            }
        }
    }

    private static func wallhaven(query: String, sorting: WallhavenSorting, page: Int) async throws -> ([OnlineImage], Int) {
        var c = URLComponents(string: "https://wallhaven.cc/api/v1/search")!
        c.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "sorting", value: sorting.rawValue),
            URLQueryItem(name: "purity", value: "100"), // SFW only
            URLQueryItem(name: "categories", value: "111"),
            URLQueryItem(name: "atleast", value: "1920x1080"),
            URLQueryItem(name: "page", value: String(page)),
        ]
        if sorting == .toplist { c.queryItems?.append(URLQueryItem(name: "topRange", value: "1M")) }

        struct Response: Decodable {
            struct Item: Decodable {
                let id: String
                let path: String
                let resolution: String
                let category: String
                let thumbs: [String: String]
            }
            struct Meta: Decodable { let last_page: Int }
            let data: [Item]
            let meta: Meta
        }
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        let response = try JSONDecoder().decode(Response.self, from: data)
        let items = response.data.compactMap { item -> OnlineImage? in
            guard let full = URL(string: item.path),
                  let thumb = URL(string: item.thumbs["large"] ?? item.thumbs["original"] ?? item.path) else { return nil }
            return OnlineImage(id: "wallhaven-" + item.id, thumb: thumb, full: full, title: item.category.capitalized,
                               detail: item.resolution, fileName: "wallhaven-\(item.id).\(full.pathExtension)")
        }
        return (items, response.meta.last_page)
    }

    private static func bing() async throws -> ([OnlineImage], Int) {
        struct Response: Decodable {
            struct Image: Decodable { let urlbase: String; let title: String; let copyright: String }
            let images: [Image]
        }
        let url = URL(string: "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=en-US")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(Response.self, from: data)
        let items = response.images.compactMap { image -> OnlineImage? in
            guard let thumb = URL(string: "https://www.bing.com\(image.urlbase)_800x480.jpg"),
                  let full = URL(string: "https://www.bing.com\(image.urlbase)_UHD.jpg") else { return nil }
            let name = image.urlbase.components(separatedBy: "OHR.").last?.components(separatedBy: "_").first ?? "image"
            return OnlineImage(id: "bing-" + name, thumb: thumb, full: full, title: image.title,
                               detail: image.copyright, fileName: "bing-\(name).jpg")
        }
        return (items, 1)
    }

    func download(_ item: OnlineImage, apply: Bool) {
        if case .done(let url) = downloads[item.id] {
            if apply { onApply?(url) }
            return
        }
        downloads[item.id] = .running
        let folder = URL(fileURLWithPath: Settings.shared.downloadFolder)
        Task {
            do {
                let saved = try await Downloader.download(item.full, to: folder, fileName: item.fileName)
                await MainActor.run {
                    self.downloads[item.id] = .done(saved)
                    Settings.shared.ensureInLibrary(folder)
                    self.onDownloaded?()
                    if apply { self.onApply?(saved) }
                }
            } catch {
                await MainActor.run { self.downloads[item.id] = .failed(error.localizedDescription) }
            }
        }
    }
}

enum Downloader {
    /// Downloads a file into `folder`, keeping an existing file with the same name.
    static func download(_ url: URL, to folder: URL, fileName: String? = nil) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = fileName ?? (url.lastPathComponent.isEmpty ? "wallpaper.jpg" : url.lastPathComponent)
        let destination = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let (temp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }
}

// MARK: - View

struct OnlineView: View {
    @ObservedObject var model: OnlineModel
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $model.source) {
                    ForEach(OnlineSource.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)

                if model.source == .wallhaven {
                    TextField("Search (e.g. mountains, city night)", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.search() }
                    Picker("", selection: $model.sorting) {
                        ForEach(WallhavenSorting.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Button("Search") { model.search() }.keyboardShortcut(.defaultAction)
                } else {
                    Spacer()
                }
            }
            .padding(12)

            Divider()

            ScrollView {
                if let error = model.error {
                    Text(error).foregroundStyle(.red).padding()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                    ForEach(model.results) { item in
                        OnlineCell(item: item, state: model.downloads[item.id]) { apply in
                            model.download(item, apply: apply)
                        }
                    }
                }
                .padding(14)

                if model.loading {
                    ProgressView().padding()
                } else if model.canLoadMore {
                    Button("Load More") { model.search(more: true) }.padding(.bottom, 20)
                }
            }

            Divider()
            HStack {
                Text("Saving to \(settings.downloadFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                Spacer()
                Text(model.source == .wallhaven ? "Images from wallhaven.cc (SFW only)" : "Images from bing.com")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(minWidth: 820, minHeight: 600)
        .onAppear { if model.results.isEmpty { model.search() } }
    }
}

struct OnlineCell: View {
    let item: OnlineImage
    let state: DownloadState?
    var onDownload: (_ apply: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: item.thumb) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                case .failure: Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
                default: ProgressView()
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture(count: 2) { onDownload(true) }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                switch state {
                case .running:
                    ProgressView().controlSize(.small)
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Downloaded")
                    Button("Apply") { onDownload(true) }.controlSize(.small)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
                    Button("Retry") { onDownload(false) }.controlSize(.small)
                case nil:
                    Button { onDownload(false) } label: { Image(systemName: "arrow.down.circle") }
                        .buttonStyle(.borderless).help("Download")
                    Button("Apply") { onDownload(true) }.controlSize(.small)
                }
            }
        }
    }
}
