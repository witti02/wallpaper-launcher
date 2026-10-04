// WallpaperLauncher – a rofi/waypaper-style wallpaper picker for macOS.
// Menu bar app; the global hotkey ⌃⌥W opens a floating, rotating ring of wallpapers.

import AppKit
import Carbon.HIToolbox
import ImageIO
import ServiceManagement
import SwiftUI

// MARK: - Preferences

enum Prefs {
    static let defaults = UserDefaults.standard
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "gif", "bmp"]

    static var folders: [URL] {
        get {
            let paths = defaults.stringArray(forKey: "folders") ?? [NSHomeDirectory() + "/Pictures/Wallpaper"]
            return paths.map { URL(fileURLWithPath: $0) }
        }
        set { defaults.set(newValue.map(\.path), forKey: "folders") }
    }

    static var closeOnApply: Bool {
        get { defaults.object(forKey: "closeOnApply") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "closeOnApply") }
    }
}

// MARK: - Model

struct Wallpaper: Identifiable, Hashable {
    let url: URL
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
        let folders = Prefs.folders
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [Wallpaper] = []
            let fm = FileManager.default
            for folder in folders {
                guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in e where Prefs.imageExtensions.contains(url.pathExtension.lowercased()) {
                    found.append(Wallpaper(url: url))
                }
            }
            let unique = Array(Set(found)).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
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
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
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
    static let size = CGSize(width: 280, height: 175)
    let wallpaper: Wallpaper
    let isCurrent: Bool
    @StateObject private var loader = ThumbLoader()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = loader.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.white.opacity(0.06))
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipped()

            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white, Color.accentColor)
                    .shadow(radius: 3)
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .task(id: wallpaper.url) { loader.image = await ThumbnailCache.shared.image(for: wallpaper.url) }
    }
}

/// Places a card on the ring. The angle is animatable so cards travel along
/// the circle while rotating instead of moving in a straight line.
struct RingSlot: ViewModifier, Animatable {
    var angle: Double // degrees, 0 = front
    let radius: CGFloat

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let rad = angle * .pi / 180
        let depth = (cos(rad) + 1) / 2 // 1 = front, 0 = back
        let front = max(0, (cos(rad) - 0.94) / 0.06)
        content
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(front), lineWidth: 3)
            )
            .shadow(color: .black.opacity(0.1 + 0.4 * depth), radius: 3 + 14 * depth, y: 2 + 8 * depth)
            .rotation3DEffect(.degrees(max(-70, min(70, angle * 0.8))), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .scaleEffect(0.3 + 0.7 * pow(depth, 1.4))
            .brightness(-0.4 * (1 - depth))
            .opacity(min(1, depth * 2.2))
            .offset(x: radius * sin(rad), y: -80 * (1 - depth))
            .zIndex(depth)
    }
}

struct RingView: View {
    @ObservedObject var store: WallpaperStore
    let list: [Wallpaper]
    var onApply: (URL) -> Void

    var body: some View {
        let n = min(list.count, 11)
        let step = 360.0 / Double(n)
        let lo = store.position - (n - 1) / 2
        ZStack {
            ForEach(Array(lo..<(lo + n)), id: \.self) { slot in
                let wp = list[((slot % list.count) + list.count) % list.count]
                ThumbView(wallpaper: wp, isCurrent: wp.url == store.current)
                    .modifier(RingSlot(angle: Double(slot - store.position) * step, radius: 330))
                    .onTapGesture(count: 2) { store.position = slot; onApply(wp.url) }
                    .onTapGesture { store.position = slot }
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: 24)
        .animation(.spring(response: 0.55, dampingFraction: 0.8), value: store.position)
    }
}

struct LauncherView: View {
    @ObservedObject var store: WallpaperStore
    var onApply: (URL) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let list = store.filtered
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search wallpapers…", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($searchFocused)
                Text("\(list.isEmpty ? 0 : store.selection + 1) / \(list.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
            .zIndex(1)

            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text(store.all.isEmpty ? "No images in your wallpaper folders" : "No matches")
                        .foregroundStyle(.secondary)
                    if store.all.isEmpty {
                        Text(Prefs.folders.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RingView(store: store, list: list, onApply: onApply)
            }

            HStack {
                Text(store.selected?.name ?? " ").font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let f = store.selected?.folder { Text(f).font(.system(size: 12)).foregroundStyle(.tertiary) }
                Spacer()
                Text("←→ / scroll rotate   ↩ apply   ⇧↩ apply & keep open   ⌘R random   esc close")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .zIndex(1)
        }
        .padding(18)
        .frame(width: LauncherPanel.size.width, height: LauncherPanel.size.height)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .onAppear { searchFocused = true }
        .onChange(of: store.focusToken) { _, _ in searchFocused = true }
    }
}

// MARK: - Panel

final class LauncherPanel: NSPanel {
    static let size = CGSize(width: 1000, height: 500)

    init(content: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let host = NSHostingView(rootView: LauncherView(store: store) { [weak self] in self?.apply($0) })
        panel = LauncherPanel(content: host)
        panel.delegate = self

        setupStatusItem()
        registerHotKey()
        installKeyMonitor()
        installScrollMonitor()

        if CommandLine.arguments.contains("--random") {
            store.reload { self.applyRandom(); NSApp.terminate(nil) }
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
        store.current = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        store.query = ""
        store.reload { self.store.selectCurrent(); self.store.focusToken += 1 }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.midX - panel.frame.width / 2,
                                         y: vf.midY - panel.frame.height / 2 + vf.height * 0.08))
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        store.focusToken += 1
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }) {
            self.panel.orderOut(nil)
        }
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    // MARK: Apply wallpaper

    func apply(_ url: URL, keepOpen: Bool = false) {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        for screen in NSScreen.screens {
            do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options) }
            catch { NSLog("Could not set wallpaper: \(error)") }
        }
        store.current = url
        if !keepOpen && Prefs.closeOnApply { hide() }
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

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let me = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { me.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        let id = EventHotKeyID(signature: OSType(0x5750_4C4C), id: 1) // 'WPLL'
        RegisterEventHotKey(UInt32(kVK_ANSI_W), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
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
        let open = menu.addItem(withTitle: "Open Launcher", action: #selector(showFromMenu), keyEquivalent: "w")
        open.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(withTitle: "Random Wallpaper", action: #selector(applyRandom), keyEquivalent: "")
        menu.addItem(.separator())

        let folders = NSMenuItem(title: "Folders", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for url in Prefs.folders {
            let item = sub.addItem(withTitle: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                                   action: #selector(folderClicked(_:)), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = "Click: show in Finder · ⌥-click: remove"
        }
        sub.addItem(.separator())
        sub.addItem(withTitle: "Add Folder…", action: #selector(addFolder), keyEquivalent: "")
        folders.submenu = sub
        menu.addItem(folders)
        menu.addItem(withTitle: "Rescan (\(store.all.count) images)", action: #selector(reloadFromMenu), keyEquivalent: "")
        menu.addItem(.separator())

        let close = menu.addItem(withTitle: "Close After Applying", action: #selector(toggleCloseOnApply), keyEquivalent: "")
        close.state = Prefs.closeOnApply ? .on : .off
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        for item in sub.items { item.target = self }
    }

    @objc func showFromMenu() { show() }
    @objc func reloadFromMenu() { store.reload() }
    @objc func toggleCloseOnApply() { Prefs.closeOnApply.toggle() }

    @objc func folderClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if NSEvent.modifierFlags.contains(.option) {
            Prefs.folders = Prefs.folders.filter { $0 != url }
            store.reload()
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        Prefs.folders = Array(Set(Prefs.folders + p.urls)).sorted { $0.path < $1.path }
        store.reload()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert(error: error)
            a.informativeText = "Tip: the app must be located in /Applications or ~/Applications for this."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    // MARK: Debug snapshot

    func snapshot(to path: String) {
        store.reload { self.store.selection = min(2, max(0, self.store.all.count - 1)) }
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let view = self.panel.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
