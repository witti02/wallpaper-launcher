import AppKit
import AVFoundation
import IOKit.ps

// MARK: - Displays

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Stable identifier that survives reboots and reconnects.
    var displayKey: String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return "\(displayID)" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static var underMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }
}

// MARK: - Engine

/// Applies wallpapers and keeps them applied: per display, across Spaces, for light/dark
/// appearance changes, and as live (video/GIF) wallpapers.
final class WallpaperEngine {
    static let shared = WallpaperEngine()
    private let settings = Settings.shared
    private let defaults = UserDefaults.standard

    /// Called after a wallpaper was applied (with the file that is actually shown).
    var onChange: ((URL) -> Void)?

    /// The wallpaper the user picked per display (before light/dark resolution).
    private(set) var assignments: [String: String] {
        didSet { defaults.set(assignments, forKey: "assignments") }
    }

    private init() {
        assignments = defaults.dictionary(forKey: "assignments") as? [String: String] ?? [:]

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.settings.allSpaces else { return }
            self.reapplyAll(onlyIfDifferent: true)
        }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            LiveWallpaper.shared.setPaused(true, reason: "sleep")
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            LiveWallpaper.shared.setPaused(false, reason: "sleep")
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.settings.lightDarkPairs else { return }
            // The effective appearance updates slightly after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.reapplyAll(onlyIfDifferent: true) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            LiveWallpaper.shared.relayout()
            self?.restoreLiveWallpapers()
        }
    }

    // MARK: Applying

    func screens(for target: DisplayTarget) -> [NSScreen] {
        switch target {
        case .all: NSScreen.screens
        case .main: NSScreen.main.map { [$0] } ?? []
        case .underMouse: NSScreen.underMouse.map { [$0] } ?? []
        }
    }

    func apply(_ url: URL, to screens: [NSScreen]) {
        for screen in screens { assignments[screen.displayKey] = url.path }
        let shown = resolveVariant(url)
        for screen in screens { show(shown, on: screen) }
        onChange?(shown)
    }

    /// The wallpaper currently assigned to a display (as picked, not resolved).
    func assigned(on screen: NSScreen) -> URL? {
        assignments[screen.displayKey].map { URL(fileURLWithPath: $0) }
    }

    func reapplyAll(onlyIfDifferent: Bool) {
        for screen in NSScreen.screens {
            guard let picked = assigned(on: screen), FileManager.default.fileExists(atPath: picked.path) else { continue }
            let shown = resolveVariant(picked)
            if onlyIfDifferent, isShowing(shown, on: screen) { continue }
            show(shown, on: screen)
        }
    }

    /// Live wallpapers only exist while the app runs, so bring them back on launch.
    func restoreLiveWallpapers() {
        for screen in NSScreen.screens {
            guard let picked = assigned(on: screen), FileManager.default.fileExists(atPath: picked.path) else { continue }
            let shown = resolveVariant(picked)
            if isLive(shown), LiveWallpaper.shared.url(on: screen) != shown { show(shown, on: screen) }
        }
    }

    private func isLive(_ url: URL) -> Bool {
        switch WallpaperKind(url: url) {
        case .video: true
        case .gif: settings.animateGIFs
        case .image: false
        }
    }

    private func isShowing(_ url: URL, on screen: NSScreen) -> Bool {
        if isLive(url) {
            return LiveWallpaper.shared.url(on: screen) == url
                && NSWorkspace.shared.desktopImageURL(for: screen) == Poster.url(for: url)
        }
        return NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL == url.standardizedFileURL
    }

    private func show(_ url: URL, on screen: NSScreen) {
        if isLive(url) {
            // Set a still frame as the real desktop picture (used by Mission Control and after quitting),
            // then play the animation in a window on the desktop level.
            if let poster = Poster.make(for: url) { setDesktopPicture(poster, on: screen) }
            if LiveWallpaper.shared.url(on: screen) != url {
                LiveWallpaper.shared.play(url, on: screen, scaling: settings.scaling)
            }
        } else {
            LiveWallpaper.shared.stop(on: screen)
            setDesktopPicture(url, on: screen)
        }
    }

    private func setDesktopPicture(_ url: URL, on screen: NSScreen) {
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        switch settings.scaling {
        case .fill:
            options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
            options[.allowClipping] = true
        case .fit:
            options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
            options[.allowClipping] = false
            options[.fillColor] = NSColor.black
        case .stretch:
            options[.imageScaling] = NSImageScaling.scaleAxesIndependently.rawValue
        case .center:
            options[.imageScaling] = NSImageScaling.scaleNone.rawValue
            options[.fillColor] = NSColor.black
        }
        do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options) }
        catch { NSLog("Could not set wallpaper: \(error)") }
    }

    // MARK: Light / dark pairs

    static var isDarkMode: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static let variantPattern = try! NSRegularExpression(
        pattern: "^(.*?)([-_ .])(light|dark|day|night)$", options: [.caseInsensitive])

    /// For `name-light.jpg` / `name-dark.jpg` (also `_`, space, `.`, and day/night) returns the variant
    /// matching the current appearance, or the file itself when there is no counterpart.
    func resolveVariant(_ url: URL) -> URL {
        guard settings.lightDarkPairs else { return url }
        return Self.variant(of: url, dark: Self.isDarkMode) ?? url
    }

    static func variant(of url: URL, dark: Bool) -> URL? {
        let base = url.deletingPathExtension().lastPathComponent
        let range = NSRange(base.startIndex..., in: base)
        guard let m = variantPattern.firstMatch(in: base, range: range),
              let stemRange = Range(m.range(at: 1), in: base),
              let sepRange = Range(m.range(at: 2), in: base) else { return nil }
        let stem = String(base[stemRange]), sep = String(base[sepRange])
        let wanted = (dark ? ["dark", "night"] : ["light", "day"]).map { (stem + sep + $0).lowercased() }

        let dir = url.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for name in wanted {
            if let match = files.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == name }) {
                return match
            }
        }
        return nil
    }

    /// Whether this wallpaper has a light/dark counterpart.
    static func hasVariant(_ url: URL) -> Bool {
        variant(of: url, dark: true) != nil && variant(of: url, dark: false) != nil
    }
}

// MARK: - Posters (still frames of live wallpapers)

enum Poster {
    static let folder: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WallpaperLauncher/Posters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for source: URL) -> URL {
        // FNV-1a hash of the path keeps file names stable across launches.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in source.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return folder.appendingPathComponent(String(hash, radix: 16) + ".png")
    }

    static func make(for source: URL) -> URL? {
        let out = url(for: source)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        guard let cg = ImageLoader.cgImage(for: source, maxPixels: 3840) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: out)
        return out
    }
}

// MARK: - Live wallpapers

/// Plays videos and animated GIFs in borderless windows on the desktop level, below the desktop icons.
final class LiveWallpaper {
    static let shared = LiveWallpaper()

    private final class Entry {
        let url: URL
        let window: NSWindow
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        var gifView: NSImageView?
        init(url: URL, window: NSWindow) { self.url = url; self.window = window }
    }

    private var entries: [String: Entry] = [:]
    private var pauseReasons: Set<String> = []

    var isActive: Bool { !entries.isEmpty }

    func url(on screen: NSScreen) -> URL? { entries[screen.displayKey]?.url }

    func play(_ url: URL, on screen: NSScreen, scaling: WallpaperScaling) {
        stop(on: screen)

        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.hasShadow = false
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = content

        let entry = Entry(url: url, window: window)
        if WallpaperKind(url: url) == .video {
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            entry.looper = AVPlayerLooper(player: player, templateItem: item)
            entry.player = player
            let layer = AVPlayerLayer(player: player)
            layer.frame = content.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.videoGravity = switch scaling {
            case .fill: .resizeAspectFill
            case .stretch: .resize
            case .fit, .center: .resizeAspect
            }
            content.layer?.addSublayer(layer)
            if pauseReasons.isEmpty { player.play() }
        } else {
            let view = NSImageView()
            view.image = NSImage(contentsOf: url)
            view.animates = pauseReasons.isEmpty
            view.imageScaling = scaling == .stretch ? .scaleAxesIndependently
                : scaling == .center ? .scaleNone : .scaleProportionallyUpOrDown
            view.frame = Self.frame(for: view.image?.size ?? .zero, in: content.bounds, fill: scaling == .fill)
            content.addSubview(view)
            entry.gifView = view
        }

        entries[screen.displayKey] = entry
        window.orderFrontRegardless()
    }

    func stop(on screen: NSScreen) {
        guard let entry = entries.removeValue(forKey: screen.displayKey) else { return }
        entry.player?.pause()
        entry.looper?.disableLooping()
        entry.window.orderOut(nil)
    }

    func stopAll() {
        for screen in NSScreen.screens { stop(on: screen) }
        entries.values.forEach { $0.window.orderOut(nil) }
        entries.removeAll()
    }

    /// Pauses for any reason (sleep, battery, …) and resumes once no reason is left.
    func setPaused(_ paused: Bool, reason: String) {
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        let running = pauseReasons.isEmpty
        for entry in entries.values {
            if running { entry.player?.play() } else { entry.player?.pause() }
            entry.gifView?.animates = running
        }
    }

    /// Follows display resolution / arrangement changes.
    func relayout() {
        let screens = Dictionary(NSScreen.screens.map { ($0.displayKey, $0) }, uniquingKeysWith: { a, _ in a })
        for (key, entry) in entries {
            guard let screen = screens[key] else {
                entry.window.orderOut(nil)
                entries.removeValue(forKey: key)
                continue
            }
            entry.window.setFrame(screen.frame, display: true)
            if let gif = entry.gifView, let bounds = entry.window.contentView?.bounds {
                gif.frame = Self.frame(for: gif.image?.size ?? .zero, in: bounds, fill: Settings.shared.scaling == .fill)
            }
        }
    }

    /// Checks the power source; called periodically.
    func updatePowerState() {
        let onBattery = Settings.shared.pauseVideosOnBattery
            && (IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String?) == kIOPMBatteryPowerKey
        setPaused(onBattery, reason: "battery")
    }

    /// Aspect-fill frame for GIFs (NSImageView can only fit, so the view is made larger than the screen).
    private static func frame(for size: CGSize, in bounds: CGRect, fill: Bool) -> CGRect {
        guard fill, size.width > 0, size.height > 0 else { return bounds }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}
