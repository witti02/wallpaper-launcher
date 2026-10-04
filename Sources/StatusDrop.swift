import AppKit

/// Transparent overlay on the menu bar button that accepts dropped images, videos and image links.
/// Clicks fall through to the button so the menu keeps working.
final class StatusDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    private weak var button: NSStatusBarButton?

    init(button: NSStatusBarButton) {
        self.button = button
        super.init(frame: button.bounds)
        autoresizingMask = [.width, .height]
        registerForDraggedTypes([.fileURL, .URL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let real mouse events reach the button; only take part in drag & drop.
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
             .mouseMoved, .mouseEntered, .mouseExited, .leftMouseDragged, .rightMouseDragged:
            return nil
        default:
            return super.hitTest(point)
        }
    }

    private func urls(from info: NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let extensions = Settings.shared.enabledExtensions
        return objects.filter { url in
            if url.isFileURL { return extensions.contains(url.pathExtension.lowercased()) }
            return url.scheme == "http" || url.scheme == "https"
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(from: sender).isEmpty else { return [] }
        button?.highlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        button?.highlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        button?.highlight(false)
        let dropped = urls(from: sender)
        guard !dropped.isEmpty else { return false }
        onDrop?(dropped)
        return true
    }
}

enum Importer {
    /// Copies dropped files (or downloads dropped links) into the download folder, unless they
    /// already live in the library. Returns the files in library locations.
    static func importFiles(_ urls: [URL]) async -> [URL] {
        let settings = Settings.shared
        let folder = URL(fileURLWithPath: settings.downloadFolder)
        var result: [URL] = []
        for url in urls {
            do {
                if url.isFileURL {
                    let path = url.standardizedFileURL.path
                    let inLibrary = settings.folders.contains { f in
                        f.enabled && (path.hasPrefix(f.path + "/")) && (f.recursive || url.deletingLastPathComponent().path == f.path)
                    }
                    if inLibrary { result.append(url); continue }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    var destination = folder.appendingPathComponent(url.lastPathComponent)
                    var n = 2
                    while FileManager.default.fileExists(atPath: destination.path) {
                        destination = folder.appendingPathComponent(
                            "\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)")
                        n += 1
                    }
                    try FileManager.default.copyItem(at: url, to: destination)
                    result.append(destination)
                } else {
                    var name = url.lastPathComponent
                    if !Settings.shared.enabledExtensions.contains((name as NSString).pathExtension.lowercased()) {
                        name = "download-\(Int(Date().timeIntervalSince1970)).jpg"
                    }
                    result.append(try await Downloader.download(url, to: folder, fileName: name))
                }
            } catch {
                NSLog("Import failed for \(url): \(error)")
            }
        }
        if !result.isEmpty { await MainActor.run { settings.ensureInLibrary(folder) } }
        return result
    }
}
