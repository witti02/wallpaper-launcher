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
    ]
}

// MARK: - Settings

/// All user settings, persisted in UserDefaults. Views observe this directly, so changes apply live.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    // Library
    @Published var folders: [WallpaperFolder] { didSet { saveFolders() } }
    @Published var imageTypes: Set<String> { didSet { defaults.set(Array(imageTypes), forKey: "imageTypes") } }
    @Published var sortOrder: SortOrder { didSet { defaults.set(sortOrder.rawValue, forKey: "sortOrder") } }

    // Behavior
    @Published var closeOnApply: Bool { didSet { defaults.set(closeOnApply, forKey: "closeOnApply") } }
    @Published var startAtCurrent: Bool { didSet { defaults.set(startAtCurrent, forKey: "startAtCurrent") } }
    @Published var scaling: WallpaperScaling { didSet { defaults.set(scaling.rawValue, forKey: "scaling") } }
    @Published var displayTarget: DisplayTarget { didSet { defaults.set(displayTarget.rawValue, forKey: "displayTarget") } }

    // Shortcut (Carbon key code + Carbon modifier mask)
    @Published var hotkeyKeyCode: Int { didSet { defaults.set(hotkeyKeyCode, forKey: "hotkeyKeyCode") } }
    @Published var hotkeyModifiers: Int { didSet { defaults.set(hotkeyModifiers, forKey: "hotkeyModifiers") } }
    @Published var hotkeyKeyName: String { didSet { defaults.set(hotkeyKeyName, forKey: "hotkeyKeyName") } }
    /// Not persisted: the global hotkey is paused while a new one is being recorded.
    @Published var isRecordingHotkey = false

    // Appearance
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

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "folderEntries"), let saved = try? JSONDecoder().decode([WallpaperFolder].self, from: data) {
            folders = saved
        } else {
            // Migrate the plain path list from version 1.0.
            let paths = d.stringArray(forKey: "folders") ?? [NSHomeDirectory() + "/Pictures/Wallpaper"]
            folders = paths.map { WallpaperFolder(path: $0) }
        }
        imageTypes = Set(d.stringArray(forKey: "imageTypes") ?? ImageType.all.map(\.id))
        sortOrder = SortOrder(rawValue: d.string(forKey: "sortOrder") ?? "") ?? .name

        closeOnApply = d.object(forKey: "closeOnApply") as? Bool ?? true
        startAtCurrent = d.object(forKey: "startAtCurrent") as? Bool ?? true
        scaling = WallpaperScaling(rawValue: d.string(forKey: "scaling") ?? "") ?? .fill
        displayTarget = DisplayTarget(rawValue: d.string(forKey: "displayTarget") ?? "") ?? .all

        hotkeyKeyCode = d.object(forKey: "hotkeyKeyCode") as? Int ?? kVK_ANSI_W
        hotkeyModifiers = d.object(forKey: "hotkeyModifiers") as? Int ?? (controlKey | optionKey)
        hotkeyKeyName = d.string(forKey: "hotkeyKeyName") ?? "W"

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
    }

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(folders) { defaults.set(data, forKey: "folderEntries") }
    }

    var enabledExtensions: Set<String> {
        Set(ImageType.all.filter { imageTypes.contains($0.id) }.flatMap(\.extensions))
    }

    func addFolders(_ urls: [URL]) {
        for url in urls where !folders.contains(where: { $0.path == url.path }) {
            folders.append(WallpaperFolder(path: url.path))
        }
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
