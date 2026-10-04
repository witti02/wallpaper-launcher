import AppKit
import Carbon.HIToolbox
import Combine

// MARK: - Option types

struct WallpaperFolder: Codable, Hashable, Identifiable {
    var path: String
    var enabled = true
    var recursive = true
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var displayPath: String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case name, newest, oldest, random
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: "Name"
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .random: "Shuffle"
        }
    }
}

enum WallpaperScaling: String, CaseIterable, Identifiable {
    case fill, fit, stretch, center
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fill: "Fill screen"
        case .fit: "Fit to screen"
        case .stretch: "Stretch"
        case .center: "Center"
        }
    }
}

enum DisplayTarget: String, CaseIterable, Identifiable {
    case all, underMouse, main
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All displays"
        case .underMouse: "Display under the mouse"
        case .main: "Main display"
        }
    }
}

enum CardShape: String, CaseIterable, Identifiable {
    case tall, portrait, square, landscape
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tall: "Tall"
        case .portrait: "Portrait"
        case .square: "Square"
        case .landscape: "Landscape"
        }
    }
    /// width / height
    var aspect: Double {
        switch self {
        case .tall: 0.38
        case .portrait: 0.62
        case .square: 1
        case .landscape: 1.6
        }
    }
}

enum RingStyle: String, CaseIterable, Identifiable {
    case ring, carousel, grid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ring: "Ring"
        case .carousel: "Carousel"
        case .grid: "Grid"
        }
    }
    var symbol: String {
        switch self {
        case .ring: "circle.dashed"
        case .carousel: "rectangle.stack"
        case .grid: "square.grid.3x3"
        }
    }
}

enum AutomationMode: String, CaseIterable, Identifiable {
    case off, interval, timeOfDay
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .interval: "Change every…"
        case .timeOfDay: "Time of day"
        }
    }
}

enum RotationPool: String, CaseIterable, Identifiable {
    case all, favorites
    var id: String { rawValue }
    var label: String { self == .all ? "All wallpapers" : "Favorites only" }
}

/// A wallpaper (or a folder to pick from) that becomes active at a given time of day.
struct TimeSlot: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var hour: Int
    var minute: Int = 0
    var path: String = ""

    var minutesOfDay: Int { hour * 60 + minute }
    var displayPath: String {
        path.isEmpty ? "Not set" : path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    static let defaults: [TimeSlot] = [
        TimeSlot(name: "Morning", hour: 6),
        TimeSlot(name: "Day", hour: 10),
        TimeSlot(name: "Evening", hour: 18),
        TimeSlot(name: "Night", hour: 21),
    ]
}

struct ImageType: Identifiable {
    let id: String
    let label: String
    let extensions: [String]

    static let all: [ImageType] = [
        ImageType(id: "jpeg", label: "JPEG", extensions: ["jpg", "jpeg"]),
        ImageType(id: "png", label: "PNG", extensions: ["png"]),
        ImageType(id: "heic", label: "HEIC", extensions: ["heic", "heif"]),
        ImageType(id: "webp", label: "WebP", extensions: ["webp"]),
        ImageType(id: "tiff", label: "TIFF", extensions: ["tif", "tiff"]),
        ImageType(id: "gif", label: "GIF", extensions: ["gif"]),
        ImageType(id: "bmp", label: "BMP", extensions: ["bmp"]),
        ImageType(id: "video", label: "Video", extensions: ["mp4", "mov", "m4v"]),
    ]
}

// MARK: - Settings

/// All user settings, persisted in UserDefaults. Views observe this directly, so changes apply live.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    // Library
    @Published var folders: [WallpaperFolder] { didSet { save(folders, "folderEntries") } }
    @Published var disabledImageTypes: Set<String> { didSet { defaults.set(Array(disabledImageTypes), forKey: "disabledImageTypes") } }
    @Published var sortOrder: SortOrder { didSet { defaults.set(sortOrder.rawValue, forKey: "sortOrder") } }
    @Published var favorites: Set<String> { didSet { defaults.set(Array(favorites), forKey: "favorites") } }
    @Published var downloadFolder: String { didSet { defaults.set(downloadFolder, forKey: "downloadFolder") } }

    // Behavior
    @Published var closeOnApply: Bool { didSet { defaults.set(closeOnApply, forKey: "closeOnApply") } }
    @Published var startAtCurrent: Bool { didSet { defaults.set(startAtCurrent, forKey: "startAtCurrent") } }
    @Published var scaling: WallpaperScaling { didSet { defaults.set(scaling.rawValue, forKey: "scaling") } }
    @Published var displayTarget: DisplayTarget { didSet { defaults.set(displayTarget.rawValue, forKey: "displayTarget") } }
    @Published var allSpaces: Bool { didSet { defaults.set(allSpaces, forKey: "allSpaces") } }
    @Published var lightDarkPairs: Bool { didSet { defaults.set(lightDarkPairs, forKey: "lightDarkPairs") } }
    @Published var animateGIFs: Bool { didSet { defaults.set(animateGIFs, forKey: "animateGIFs") } }
    @Published var pauseVideosOnBattery: Bool { didSet { defaults.set(pauseVideosOnBattery, forKey: "pauseVideosOnBattery") } }

    // Shortcut (Carbon key code + Carbon modifier mask)
    @Published var hotkeyKeyCode: Int { didSet { defaults.set(hotkeyKeyCode, forKey: "hotkeyKeyCode") } }
    @Published var hotkeyModifiers: Int { didSet { defaults.set(hotkeyModifiers, forKey: "hotkeyModifiers") } }
    @Published var hotkeyKeyName: String { didSet { defaults.set(hotkeyKeyName, forKey: "hotkeyKeyName") } }
    /// Not persisted: the global hotkey is paused while a new one is being recorded.
    @Published var isRecordingHotkey = false

    // Automation
    @Published var automation: AutomationMode { didSet { defaults.set(automation.rawValue, forKey: "automation") } }
    @Published var intervalMinutes: Int { didSet { defaults.set(intervalMinutes, forKey: "intervalMinutes") } }
    @Published var rotationPool: RotationPool { didSet { defaults.set(rotationPool.rawValue, forKey: "rotationPool") } }
    @Published var rotationShuffle: Bool { didSet { defaults.set(rotationShuffle, forKey: "rotationShuffle") } }
    @Published var timeSlots: [TimeSlot] { didSet { save(timeSlots, "timeSlots") } }

    // Colors
    @Published var matchAccent: Bool { didSet { defaults.set(matchAccent, forKey: "matchAccent") } }
    @Published var exportPalette: Bool { didSet { defaults.set(exportPalette, forKey: "exportPalette") } }
    @Published var paletteFolder: String { didSet { defaults.set(paletteFolder, forKey: "paletteFolder") } }
    @Published var postChangeCommand: String { didSet { defaults.set(postChangeCommand, forKey: "postChangeCommand") } }

    // Updates & app icons
    @Published var checkForUpdates: Bool { didSet { defaults.set(checkForUpdates, forKey: "checkForUpdates") } }
    @Published var showInDock: Bool { didSet { defaults.set(showInDock, forKey: "showInDock") } }
    @Published var showInMenuBar: Bool { didSet { defaults.set(showInMenuBar, forKey: "showInMenuBar") } }

    // Appearance
    @Published var ringStyle: RingStyle { didSet { defaults.set(ringStyle.rawValue, forKey: "ringStyle") } }
    @Published var livePreview: Bool { didSet { defaults.set(livePreview, forKey: "livePreview") } }
    @Published var blurRadius: Double { didSet { defaults.set(blurRadius, forKey: "blurRadius") } }
    @Published var dimming: Double { didSet { defaults.set(dimming, forKey: "dimming") } }
    @Published var cardSize: Double { didSet { defaults.set(cardSize, forKey: "cardSize") } }
    @Published var cardShape: CardShape { didSet { defaults.set(cardShape.rawValue, forKey: "cardShape") } }
    @Published var cornerRadius: Double { didSet { defaults.set(cornerRadius, forKey: "cornerRadius") } }
    @Published var cardSpacing: Double { didSet { defaults.set(cardSpacing, forKey: "cardSpacing") } }
    @Published var ringRadius: Double { didSet { defaults.set(ringRadius, forKey: "ringRadius") } }
    @Published var visibleCards: Int { didSet { defaults.set(visibleCards, forKey: "visibleCards") } }
    @Published var sideDimming: Double { didSet { defaults.set(sideDimming, forKey: "sideDimming") } }
    @Published var animationSpeed: Double { didSet { defaults.set(animationSpeed, forKey: "animationSpeed") } }
    @Published var spinIn: Bool { didSet { defaults.set(spinIn, forKey: "spinIn") } }
    @Published var showSearchBar: Bool { didSet { defaults.set(showSearchBar, forKey: "showSearchBar") } }
    @Published var showHints: Bool { didSet { defaults.set(showHints, forKey: "showHints") } }
    @Published var showTabs: Bool { didSet { defaults.set(showTabs, forKey: "showTabs") } }

    private init() {
        let d = UserDefaults.standard
        let pictures = NSHomeDirectory() + "/Pictures/Wallpaper"

        if let saved: [WallpaperFolder] = Self.load(d, "folderEntries") {
            folders = saved
        } else {
            // Migrate the plain path list from version 1.0.
            folders = (d.stringArray(forKey: "folders") ?? [pictures]).map { WallpaperFolder(path: $0) }
        }
        if let disabled = d.stringArray(forKey: "disabledImageTypes") {
            disabledImageTypes = Set(disabled)
        } else if let enabled = d.stringArray(forKey: "imageTypes") {
            // Migrate the enabled list from version 1.0; new types (video) start enabled.
            disabledImageTypes = Set(ImageType.all.map(\.id)).subtracting(enabled).subtracting(["video"])
        } else {
            disabledImageTypes = []
        }
        sortOrder = SortOrder(rawValue: d.string(forKey: "sortOrder") ?? "") ?? .name
        favorites = Set(d.stringArray(forKey: "favorites") ?? [])
        downloadFolder = d.string(forKey: "downloadFolder") ?? pictures + "/Downloads"

        closeOnApply = d.object(forKey: "closeOnApply") as? Bool ?? true
        startAtCurrent = d.object(forKey: "startAtCurrent") as? Bool ?? true
        scaling = WallpaperScaling(rawValue: d.string(forKey: "scaling") ?? "") ?? .fill
        displayTarget = DisplayTarget(rawValue: d.string(forKey: "displayTarget") ?? "") ?? .all
        allSpaces = d.object(forKey: "allSpaces") as? Bool ?? true
        lightDarkPairs = d.object(forKey: "lightDarkPairs") as? Bool ?? true
        animateGIFs = d.object(forKey: "animateGIFs") as? Bool ?? true
        pauseVideosOnBattery = d.object(forKey: "pauseVideosOnBattery") as? Bool ?? true

        hotkeyKeyCode = d.object(forKey: "hotkeyKeyCode") as? Int ?? kVK_ANSI_W
        hotkeyModifiers = d.object(forKey: "hotkeyModifiers") as? Int ?? (controlKey | optionKey)
        hotkeyKeyName = d.string(forKey: "hotkeyKeyName") ?? "W"

        automation = AutomationMode(rawValue: d.string(forKey: "automation") ?? "") ?? .off
        intervalMinutes = d.object(forKey: "intervalMinutes") as? Int ?? 30
        rotationPool = RotationPool(rawValue: d.string(forKey: "rotationPool") ?? "") ?? .all
        rotationShuffle = d.object(forKey: "rotationShuffle") as? Bool ?? true
        timeSlots = Self.load(d, "timeSlots") ?? TimeSlot.defaults

        matchAccent = d.object(forKey: "matchAccent") as? Bool ?? true
        exportPalette = d.object(forKey: "exportPalette") as? Bool ?? false
        paletteFolder = d.string(forKey: "paletteFolder") ?? NSHomeDirectory() + "/.cache/wallpaper-launcher"
        postChangeCommand = d.string(forKey: "postChangeCommand") ?? ""

        checkForUpdates = d.object(forKey: "checkForUpdates") as? Bool ?? true
        // On by default: macOS 27 can hide menu bar icons, and the Dock icon keeps the app reachable.
        showInDock = d.object(forKey: "showInDock") as? Bool ?? true
        showInMenuBar = d.object(forKey: "showInMenuBar") as? Bool ?? true

        ringStyle = RingStyle(rawValue: d.string(forKey: "ringStyle") ?? "") ?? .ring
        livePreview = d.object(forKey: "livePreview") as? Bool ?? true
        blurRadius = d.object(forKey: "blurRadius") as? Double ?? Defaults.blurRadius
        dimming = d.object(forKey: "dimming") as? Double ?? Defaults.dimming
        cardSize = d.object(forKey: "cardSize") as? Double ?? Defaults.cardSize
        cardShape = CardShape(rawValue: d.string(forKey: "cardShape") ?? "") ?? Defaults.cardShape
        cornerRadius = d.object(forKey: "cornerRadius") as? Double ?? Defaults.cornerRadius
        cardSpacing = d.object(forKey: "cardSpacing") as? Double ?? Defaults.cardSpacing
        ringRadius = d.object(forKey: "ringRadius") as? Double ?? Defaults.ringRadius
        visibleCards = d.object(forKey: "visibleCards") as? Int ?? Defaults.visibleCards
        sideDimming = d.object(forKey: "sideDimming") as? Double ?? Defaults.sideDimming
        animationSpeed = d.object(forKey: "animationSpeed") as? Double ?? Defaults.animationSpeed
        spinIn = d.object(forKey: "spinIn") as? Bool ?? true
        showSearchBar = d.object(forKey: "showSearchBar") as? Bool ?? true
        showHints = d.object(forKey: "showHints") as? Bool ?? true
        showTabs = d.object(forKey: "showTabs") as? Bool ?? true
    }

    enum Defaults {
        static let blurRadius = 14.0
        static let dimming = 0.15
        static let cardSize = 0.42
        static let cardShape = CardShape.tall
        static let cornerRadius = 6.0
        static let cardSpacing = 11.0
        static let ringRadius = 0.74
        static let visibleCards = 15
        static let sideDimming = 0.45
        static let animationSpeed = 1.0
    }

    func resetAppearance() {
        ringStyle = .ring
        livePreview = true
        blurRadius = Defaults.blurRadius
        dimming = Defaults.dimming
        cardSize = Defaults.cardSize
        cardShape = Defaults.cardShape
        cornerRadius = Defaults.cornerRadius
        cardSpacing = Defaults.cardSpacing
        ringRadius = Defaults.ringRadius
        visibleCards = Defaults.visibleCards
        sideDimming = Defaults.sideDimming
        animationSpeed = Defaults.animationSpeed
        spinIn = true
        showSearchBar = true
        showHints = true
        showTabs = true
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ d: UserDefaults, _ key: String) -> T? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    var enabledExtensions: Set<String> {
        Set(ImageType.all.filter { !disabledImageTypes.contains($0.id) }.flatMap(\.extensions))
    }

    func addFolders(_ urls: [URL]) {
        for url in urls where !folders.contains(where: { $0.path == url.path }) {
            folders.append(WallpaperFolder(path: url.path))
        }
    }

    /// Makes sure files saved to `url` show up in the library.
    func ensureInLibrary(_ url: URL) {
        let path = url.standardizedFileURL.path
        let covered = folders.contains { f in
            f.enabled && (path == f.path || (f.recursive && path.hasPrefix(f.path + "/")))
        }
        if !covered { addFolders([url]) }
    }

    func isFavorite(_ url: URL) -> Bool { favorites.contains(url.path) }

    func toggleFavorite(_ url: URL) {
        if favorites.contains(url.path) { favorites.remove(url.path) } else { favorites.insert(url.path) }
    }

    // MARK: Shortcut display

    var hotkeyDisplay: String {
        var s = ""
        if hotkeyModifiers & controlKey != 0 { s += "⌃" }
        if hotkeyModifiers & optionKey != 0 { s += "⌥" }
        if hotkeyModifiers & shiftKey != 0 { s += "⇧" }
        if hotkeyModifiers & cmdKey != 0 { s += "⌘" }
        return s + hotkeyKeyName
    }

    static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func isFunctionKey(_ keyCode: Int) -> Bool {
        specialKeyNames[keyCode]?.hasPrefix("F") == true
    }
}
