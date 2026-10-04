import AppKit
import AVFoundation
import ImageIO
import SwiftUI

// MARK: - Wallpaper

enum WallpaperKind {
    case image, gif, video

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    init(url: URL) {
        let ext = url.pathExtension.lowercased()
        if Self.videoExtensions.contains(ext) { self = .video }
        else if ext == "gif" { self = .gif }
        else { self = .image }
    }
}

struct Wallpaper: Identifiable, Hashable {
    let url: URL
    var modified = Date.distantPast
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var folder: String { url.deletingLastPathComponent().lastPathComponent }
    var directory: URL { url.deletingLastPathComponent() }
    var kind: WallpaperKind { WallpaperKind(url: url) }
}

/// A tab in the launcher: everything, favorites, or one directory.
enum LibraryTab: Hashable {
    case all, favorites
    case folder(URL)

    var title: String {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .folder(let url): url.lastPathComponent
        }
    }
}

// MARK: - Store

final class WallpaperStore: ObservableObject {
    @Published var all: [Wallpaper] = []
    @Published var query = "" { didSet { position = 0 } }
    @Published var tab: LibraryTab = .all { didSet { if tab != oldValue { position = 0 } } }
    /// Unwrapped ring position; the selection is position mod count.
    @Published var position = 0
    @Published var current: URL?
    @Published var focusToken = 0
    /// Extra ring rotation in degrees, used for the spin-in animation.
    @Published var spin: Double = 0
    /// True when the window server blur is unavailable and the view must blur the backdrop itself.
    @Published var needsFallbackBlur = false
    /// Accent color taken from the current wallpaper.
    @Published var accent: Color = .accentColor
    /// Display the launcher applies to; nil follows the setting.
    @Published var targetDisplay: Int?
    /// Number of columns in the grid style, reported by the grid view for keyboard navigation.
    var gridColumns = 1

    private let settings = Settings.shared

    var tabs: [LibraryTab] {
        var result: [LibraryTab] = [.all]
        if !settings.favorites.isEmpty { result.append(.favorites) }
        // Only offer folder tabs when there is more than one folder to choose from.
        let dirs = Set(all.map(\.directory))
        if dirs.count > 1 {
            result += dirs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { .folder($0) }
        }
        return result
    }

    var filtered: [Wallpaper] {
        var list: [Wallpaper]
        switch tab {
        case .all: list = all
        case .favorites: list = all.filter { settings.isFavorite($0.url) }
        case .folder(let dir): list = all.filter { $0.directory == dir }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.folder.localizedCaseInsensitiveContains(q) }
    }

    var selection: Int {
        get {
            let c = filtered.count
            return c == 0 ? 0 : ((position % c) + c) % c
        }
        set {
            // Rotate to the target along the shortest path.
            let c = filtered.count
            guard c > 0 else { position = 0; return }
            var d = (newValue - selection) % c
            if d > c / 2 { d -= c } else if d < -c / 2 { d += c }
            position += d
        }
    }

    var selected: Wallpaper? {
        let list = filtered
        return list.indices.contains(selection) ? list[selection] : nil
    }

    func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        position += delta
    }

    /// Grid navigation: moves without wrapping around.
    func moveClamped(_ delta: Int) {
        let target = selection + delta
        guard filtered.indices.contains(target) else { return }
        selection = target
    }

    func switchTab(_ delta: Int) {
        let list = tabs
        guard list.count > 1 else { return }
        let i = list.firstIndex(of: tab) ?? 0
        tab = list[(i + delta + list.count) % list.count]
    }

    func selectCurrent() {
        if let current, let i = filtered.firstIndex(where: { $0.url == current }) { selection = i }
    }

    func reload(completion: (() -> Void)? = nil) {
        let folders = settings.folders.filter(\.enabled)
        let extensions = settings.enabledExtensions
        let order = settings.sortOrder
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [URL: Wallpaper] = [:]
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
            for folder in folders {
                var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
                if !folder.recursive { options.insert(.skipsSubdirectoryDescendants) }
                guard let e = fm.enumerator(at: folder.url, includingPropertiesForKeys: keys, options: options) else { continue }
                for case let url as URL in e where extensions.contains(url.pathExtension.lowercased()) {
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    found[url.standardizedFileURL] = Wallpaper(url: url.standardizedFileURL, modified: date ?? .distantPast)
                }
            }
            var unique = Array(found.values)
            switch order {
            case .name: unique.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case .newest: unique.sort { $0.modified > $1.modified }
            case .oldest: unique.sort { $0.modified < $1.modified }
            case .random: unique.shuffle()
            }
            DispatchQueue.main.async {
                self.all = unique
                if !self.tabs.contains(self.tab) { self.tab = .all }
                if self.selection >= self.filtered.count { self.selection = 0 }
                completion?()
            }
        }
    }
}

// MARK: - Image loading

enum ImageLoader {
    /// Loads a downsampled image; for videos the first frame is used.
    static func cgImage(for url: URL, maxPixels: Int) -> CGImage? {
        if WallpaperKind(url: url) == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            return try? generator.copyCGImage(at: .zero, actualTime: nil)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// Small card thumbnails and large live-preview images, cached in memory.
final class ThumbnailCache {
    static let shared = ThumbnailCache(maxPixels: 640, countLimit: 400)
    static let previews = ThumbnailCache(maxPixels: 2400, countLimit: 6)

    private let cache = NSCache<NSURL, NSImage>()
    private let maxPixels: Int

    init(maxPixels: Int, countLimit: Int) {
        self.maxPixels = maxPixels
        cache.countLimit = countLimit
    }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func image(for url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        let max = maxPixels
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let cg = ImageLoader.cgImage(for: url, maxPixels: max) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
    }

    func store(_ image: NSImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
