// WallpaperLauncher – a rofi/waypaper-style wallpaper picker for macOS.
// Menu bar app; a global hotkey (default ⌃⌥W) opens a floating, rotating ring of wallpapers.

import AppKit
import Carbon.HIToolbox
import Combine
import ImageIO
import SwiftUI

// MARK: - Model

struct Wallpaper: Identifiable, Hashable {
    let url: URL
    var modified = Date.distantPast
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var folder: String { url.deletingLastPathComponent().lastPathComponent }
}

final class WallpaperStore: ObservableObject {
    @Published var all: [Wallpaper] = []
    @Published var query = "" { didSet { position = 0 } }
    /// Unwrapped ring position; the selection is position mod count.
    @Published var position = 0
    @Published var current: URL?
    @Published var focusToken = 0
    /// Extra ring rotation in degrees, used for the spin-in animation.
    @Published var spin: Double = 0
    /// True when the window server blur is unavailable and the view must blur the backdrop itself.
    @Published var needsFallbackBlur = false

    var filtered: [Wallpaper] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.folder.localizedCaseInsensitiveContains(q) }
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

    func selectCurrent() {
        if let current, let i = filtered.firstIndex(where: { $0.url == current }) { selection = i }
    }

    func reload(completion: (() -> Void)? = nil) {
        let settings = Settings.shared
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
                    found[url] = Wallpaper(url: url, modified: date ?? .distantPast)
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
                if self.selection >= self.filtered.count { self.selection = 0 }
                completion?()
            }
        }
    }
}

// MARK: - Thumbnails

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
    }
}

// MARK: - Views

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

final class ThumbLoader: ObservableObject {
    @Published var image: NSImage?
}

struct ThumbView: View {
    let wallpaper: Wallpaper
    let isCurrent: Bool
    let size: CGSize
    let cornerRadius: Double
    @StateObject private var loader = ThumbLoader()

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if let image = loader.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.white.opacity(0.06))
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()

            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white, Color.accentColor)
                    .shadow(radius: 3)
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: wallpaper.url) { loader.image = await ThumbnailCache.shared.image(for: wallpaper.url) }
    }
}

/// Places a card on a cylinder seen from the front. The angle is animatable so cards
/// travel along the circle while the ring rotates instead of moving in a straight line.
struct RingSlot: ViewModifier, Animatable {
    var angle: Double // degrees, 0 = front
    let radius: Double
    let fadeAngle: Double // cards fade out when approaching this angle
    let step: Double
    let cornerRadius: Double
    let sideDimming: Double

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let rad: Double = angle * Double.pi / 180
        let camera: Double = radius * 1.5
        let depth: Double = radius * (1 - cos(rad)) // distance behind the front card
        let scale: Double = camera / (camera + depth)
        let x: Double = radius * sin(rad) * scale
        let edge: Double = max(0, min(1, (fadeAngle - abs(angle)) / step))
        let front: Double = max(0, 1 - abs(angle) / (step * 0.6))
        let shadow: Double = 16 * scale
        let zoom: Double = scale * (1 + 0.07 * front)
        let dim: Double = -sideDimming * (1 - scale)
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.85 * front), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.45), radius: shadow, y: shadow * 0.6)
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
            .scaleEffect(zoom)
            .brightness(dim)
            .opacity(edge)
            .offset(x: x)
            .zIndex(-depth)
    }
}

struct RingView: View {
    @ObservedObject var store: WallpaperStore
    @ObservedObject var settings = Settings.shared
    let list: [Wallpaper]
    var onApply: (URL) -> Void

    var body: some View {
        GeometryReader { geo in
            let w: Double = geo.size.width
            let h: Double = geo.size.height
            let aspect: Double = settings.cardShape.aspect
            let cardH: Double = min(h * settings.cardSize, w * settings.cardSize * 0.4 / aspect)
            let card = CGSize(width: cardH * aspect, height: cardH)
            let radius: Double = w * settings.ringRadius
            let step: Double = settings.cardSpacing
            let n: Int = min(list.count, settings.visibleCards, Int(170 / step) | 1)
            let corner: Double = settings.cornerRadius
            let lo: Int = store.position - (n - 1) / 2
            let fade: Double = Double(n / 2 + 1) * step
            ZStack {
                ForEach(Array(lo..<(lo + n)), id: \.self) { slot in
                    let wp: Wallpaper = list[((slot % list.count) + list.count) % list.count]
                    let angle: Double = Double(slot - store.position) * step + store.spin
                    ThumbView(wallpaper: wp, isCurrent: wp.url == store.current, size: card, cornerRadius: corner)
                        .modifier(RingSlot(angle: angle, radius: radius, fadeAngle: fade, step: step,
                                           cornerRadius: corner, sideDimming: settings.sideDimming))
                        .onTapGesture(count: 2) { store.position = slot; onApply(wp.url) }
                        .onTapGesture { store.position = slot }
                        .transition(.opacity)
                }
            }
            .frame(width: w, height: h)
            .offset(y: -h * 0.03)
        }
        .animation(.spring(response: 0.55 / settings.animationSpeed, dampingFraction: 0.82), value: store.position)
    }
}

struct LauncherView: View {
    @ObservedObject var store: WallpaperStore
    @ObservedObject var settings = Settings.shared
    var onApply: (URL) -> Void
    var onDismiss: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let list = store.filtered
        ZStack {
            ZStack {
                if store.needsFallbackBlur && settings.blurRadius > 0 {
                    VisualEffect(material: .fullScreenUI).opacity(min(1, settings.blurRadius / 25))
                }
                Color.black.opacity(settings.dimming)
            }
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40))
                    Text(store.all.isEmpty ? "No images in your wallpaper folders" : "No matches")
                    if store.all.isEmpty {
                        Text(settings.folders.filter(\.enabled).map(\.displayPath).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.white.opacity(0.7))
                .allowsHitTesting(false)
            } else {
                RingView(store: store, list: list, onApply: onApply)
            }

            VStack(spacing: 8) {
                Spacer()
                if settings.showSearchBar {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search wallpapers…", text: $store.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .frame(width: 200)
                        .focused($searchFocused)
                    Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 16)
                    Text(store.selected?.name ?? "–")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .leading)
                    Text("\(list.isEmpty ? 0 : store.selection + 1)/\(list.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(VisualEffect())
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                }

                if settings.showHints {
                    Text("←→ / scroll rotate   ↩ apply   ⇧↩ apply & keep open   ⌘R random   ⌘, settings   esc close")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.bottom, 48)
        }
        .environment(\.colorScheme, .dark)
        .onAppear { searchFocused = true }
        .onChange(of: store.focusToken) { _, _ in searchFocused = true }
    }
}

// MARK: - Backdrop blur

/// Light, adjustable blur behind a transparent window. Uses the window server call that
/// Terminal & co. use for their background blur; NSVisualEffectView only offers a strong fixed blur.
enum BackdropBlur {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetBlurRadius = @convention(c) (Int32, Int32, Int32) -> Int32

    private static let functions: (MainConnection, SetBlurRadius)? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let conn = dlsym(handle, "CGSMainConnectionID"),
              let blur = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return (unsafeBitCast(conn, to: MainConnection.self), unsafeBitCast(blur, to: SetBlurRadius.self))
    }()

    /// Returns false if the blur could not be applied.
    @discardableResult
    static func set(_ radius: Int, on window: NSWindow) -> Bool {
        guard let (conn, blur) = functions, window.windowNumber > 0 else { return false }
        return blur(conn(), Int32(window.windowNumber), Int32(radius)) == 0
    }
}

// MARK: - Panel

final class LauncherPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSScreen.main?.frame ?? .zero,
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        contentView = content
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let store = WallpaperStore()
    var panel: LauncherPanel!
    var statusItem: NSStatusItem!
    var keyMonitor: Any?
    var scrollMonitor: Any?
    var scrollAccum: CGFloat = 0
    var hotKeyRef: EventHotKeyRef?
    var settingsWindow: NSWindow?
    var cancellables = Set<AnyCancellable>()
    let settings = Settings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let host = NSHostingView(rootView: LauncherView(store: store,
                                                        onApply: { [weak self] in self?.apply($0) },
                                                        onDismiss: { [weak self] in self?.hide() }))
        panel = LauncherPanel(content: host)
        panel.delegate = self

        setupStatusItem()
        installHotKeyHandler()
        installKeyMonitor()
        installScrollMonitor()
        observeSettings()

        if CommandLine.arguments.contains("--random") {
            store.reload { self.applyRandom(); NSApp.terminate(nil) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-settings"), i + 1 < CommandLine.arguments.count {
            snapshotSettings(tab: Int(CommandLine.arguments[safe: i + 2] ?? "") ?? 0, to: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            snapshot(to: CommandLine.arguments[i + 1])
            return
        }
        store.reload()
        if !CommandLine.arguments.contains("--background") { show() }
    }

    // Running `open -a WallpaperLauncher` again toggles the launcher (handy for skhd/Hammerspoon).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        toggle()
        return false
    }

    // MARK: Show / hide

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        store.current = targetScreens().first.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        store.query = ""
        store.reload {
            if self.settings.startAtCurrent { self.store.selectCurrent() }
            self.store.focusToken += 1
        }

        fitPanelToScreen()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        applyBlur()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        store.focusToken += 1

        // Spin the ring in.
        guard settings.spinIn else { return }
        store.spin = 40
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.8 / self.settings.animationSpeed, dampingFraction: 0.85)) { self.store.spin = 0 }
        }
    }

    func applyBlur() {
        store.needsFallbackBlur = !BackdropBlur.set(Int(settings.blurRadius.rounded()), on: panel)
    }

    func fitPanelToScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.frame { panel.setFrame(frame, display: false) }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }) {
            self.panel.orderOut(nil)
        }
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    // MARK: Apply wallpaper

    func apply(_ url: URL, keepOpen: Bool = false) {
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
        for screen in targetScreens() {
            do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options) }
            catch { NSLog("Could not set wallpaper: \(error)") }
        }
        store.current = url
        if !keepOpen && settings.closeOnApply { hide() }
    }

    func targetScreens() -> [NSScreen] {
        switch settings.displayTarget {
        case .all: return NSScreen.screens
        case .main: return NSScreen.main.map { [$0] } ?? []
        case .underMouse:
            let mouse = NSEvent.mouseLocation
            return [NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main].compactMap { $0 }
        }
    }

    @objc func applyRandom() {
        let candidates = store.all.filter { $0.url != store.current }
        if let pick = (candidates.isEmpty ? store.all : candidates).randomElement() {
            apply(pick.url, keepOpen: panel.isVisible)
            store.selectCurrent()
        }
    }

    // MARK: Keyboard

    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch Int(event.keyCode) {
            case kVK_LeftArrow, kVK_UpArrow: self.store.move(-1)
            case kVK_RightArrow, kVK_DownArrow, kVK_Tab: self.store.move(flags.contains(.shift) ? -1 : 1)
            case kVK_Home: self.store.selection = 0
            case kVK_End: self.store.selection = max(0, self.store.filtered.count - 1)
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if let wp = self.store.selected { self.apply(wp.url, keepOpen: flags.contains(.shift)) }
            case kVK_Escape:
                if self.store.query.isEmpty { self.hide() } else { self.store.query = "" }
            case kVK_ANSI_R where flags.contains(.command): self.applyRandom()
            case kVK_ANSI_W where flags.contains(.command): self.hide()
            case kVK_ANSI_Comma where flags.contains(.command): self.openSettings()
            default: return event
            }
            return nil
        }
    }

    func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            let raw = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 45 : 1
            self.scrollAccum -= raw
            while abs(self.scrollAccum) >= threshold {
                let dir = self.scrollAccum > 0 ? 1 : -1
                self.store.move(dir)
                self.scrollAccum -= CGFloat(dir) * threshold
            }
            if event.phase == .ended || event.momentumPhase == .ended { self.scrollAccum = 0 }
            return nil
        }
    }

    func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let me = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { me.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// (Re-)registers the global shortcut; passing nil just unregisters it.
    func registerHotKey(keyCode: Int?, modifiers: Int) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        guard let keyCode else { return }
        let id = EventHotKeyID(signature: OSType(0x5750_4C4C), id: 1) // 'WPLL'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // MARK: Settings

    func observeSettings() {
        // @Published emits the new values before they are stored, so use the emitted values.
        Publishers.CombineLatest3(settings.$hotkeyKeyCode, settings.$hotkeyModifiers, settings.$isRecordingHotkey)
            .sink { [weak self] code, mods, recording in
                self?.registerHotKey(keyCode: recording ? nil : code, modifiers: mods)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(settings.$folders, settings.$imageTypes, settings.$sortOrder)
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.store.reload() }
            .store(in: &cancellables)

        settings.$blurRadius
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in if self?.panel.isVisible == true { self?.applyBlur() } }
            .store(in: &cancellables)
    }

    @objc func openSettings() {
        if panel.isVisible { hide() }
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, store: store) { [weak self] in self?.show() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "WallpaperLauncher Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Wallpaper")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = menu.addItem(withTitle: "Open Launcher", action: #selector(showFromMenu), keyEquivalent: "")
        if settings.hotkeyKeyName.count == 1 {
            open.keyEquivalent = settings.hotkeyKeyName.lowercased()
            var mask: NSEvent.ModifierFlags = []
            if settings.hotkeyModifiers & controlKey != 0 { mask.insert(.control) }
            if settings.hotkeyModifiers & optionKey != 0 { mask.insert(.option) }
            if settings.hotkeyModifiers & shiftKey != 0 { mask.insert(.shift) }
            if settings.hotkeyModifiers & cmdKey != 0 { mask.insert(.command) }
            open.keyEquivalentModifierMask = mask
        }
        menu.addItem(withTitle: "Random Wallpaper", action: #selector(applyRandom), keyEquivalent: "")
        menu.addItem(withTitle: "Rescan (\(store.all.count) images)", action: #selector(reloadFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    @objc func showFromMenu() { show() }
    @objc func reloadFromMenu() { store.reload() }

    // MARK: Debug snapshot

    func snapshotSettings(tab: Int, to path: String) {
        store.reload()
        let view = SettingsView(settings: settings, store: store, initialTab: tab) {}
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }

    func snapshot(to path: String) {
        store.reload { self.store.selection = min(2, max(0, self.store.all.count - 1)) }
        fitPanelToScreen()
        panel.orderFrontRegardless()
        applyBlur()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let view = self.panel.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
