// WallpaperLauncher – a rofi/waypaper-style wallpaper picker for macOS.
// Menu bar app; a global hotkey (default ⌃⌥W) opens a floating, rotating ring of wallpapers.

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

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

final class AppDelegate: NSObject, ObservableObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let store = WallpaperStore()
    let settings = Settings.shared
    let engine = WallpaperEngine.shared
    var panel: LauncherPanel!
    var statusItem: NSStatusItem!
    var automation: Automation!
    var keyMonitor: Any?
    var scrollMonitor: Any?
    var scrollAccum: CGFloat = 0
    var hotKeyRef: EventHotKeyRef?
    var settingsWindow: NSWindow?
    var onlineWindow: NSWindow?
    let onlineModel = OnlineModel()
    var cancellables = Set<AnyCancellable>()
    var palettes: [URL: Palette] = [:]
    @Published var currentPalette: Palette?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = makeMainMenu()

        if let i = CommandLine.arguments.firstIndex(of: "--render-demo"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            MainActor.assumeIsolated { DemoRenderer.render(to: path) }
            return
        }

        let host = NSHostingView(rootView: LauncherView(
            store: store,
            onApply: { [weak self] in self?.apply($0) },
            onDismiss: { [weak self] in self?.hide() },
            onCycleDisplay: { [weak self] in self?.cycleDisplay() },
            onCycleStyle: { [weak self] in self?.cycleStyle() }))
        panel = LauncherPanel(content: host)
        panel.delegate = self

        engine.onChange = { [weak self] in self?.wallpaperChanged($0) }
        onlineModel.onApply = { [weak self] url in
            self?.store.reload()
            self?.apply(url, keepOpen: true)
        }
        onlineModel.onDownloaded = { [weak self] in self?.store.reload() }

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

        applyIconSettings()
        engine.restoreLiveWallpapers()
        automation = Automation(store: store) { [weak self] url in self?.applyAutomatically(url) }
        store.reload { self.automation.tick() }
        if let current = currentWallpaper() { updatePalette(for: current, export: false) }
        Updater.shared.checkInBackground()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in Updater.shared.checkInBackground() }

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
        store.targetDisplay = nil
        store.current = currentWallpaper()
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
        guard settings.spinIn, settings.ringStyle != .grid else { return }
        store.spin = 40
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.8 / self.settings.animationSpeed, dampingFraction: 0.85)) { self.store.spin = 0 }
        }
    }

    func applyBlur() {
        // With live preview the selected wallpaper fills the screen, so no backdrop blur is needed.
        let radius = settings.livePreview ? 0 : Int(settings.blurRadius.rounded())
        store.needsFallbackBlur = !BackdropBlur.set(radius, on: panel)
    }

    func fitPanelToScreen() {
        if let frame = NSScreen.underMouse?.frame { panel.setFrame(frame, display: false) }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }) {
            self.panel.orderOut(nil)
        }
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    // MARK: Apply wallpaper

    /// The wallpaper shown on the target display, as the user picked it.
    func currentWallpaper() -> URL? {
        guard let screen = targetScreens().first else { return nil }
        let shown = NSWorkspace.shared.desktopImageURL(for: screen)
        if let picked = engine.assigned(on: screen) {
            let resolved = engine.resolveVariant(picked)
            if shown == resolved || shown == Poster.url(for: resolved) || LiveWallpaper.shared.url(on: screen) == resolved {
                return picked
            }
        }
        return shown
    }

    func targetScreens() -> [NSScreen] {
        if let i = store.targetDisplay, let screen = NSScreen.screens[safe: i] { return [screen] }
        return engine.screens(for: settings.displayTarget)
    }

    func apply(_ url: URL, keepOpen: Bool = false) {
        engine.apply(url, to: targetScreens())
        store.current = url
        if !keepOpen && settings.closeOnApply { hide() }
    }

    func applyAutomatically(_ url: URL) {
        engine.apply(url, to: engine.screens(for: settings.displayTarget))
        store.current = url
    }

    @objc func applyRandom() {
        let candidates = store.all.filter { $0.url != store.current }
        if let pick = (candidates.isEmpty ? store.all : candidates).randomElement() {
            apply(pick.url, keepOpen: panel.isVisible)
            store.selectCurrent()
        }
    }

    @objc func nextWallpaper() { automation.next() }

    /// Accent color, palette export and the user's hook after every change.
    func wallpaperChanged(_ shown: URL) {
        updatePalette(for: shown, export: true)
    }

    func updatePalette(for url: URL, export: Bool) {
        let settings = settings
        DispatchQueue.global(qos: .utility).async {
            let palette = self.palettes[url] ?? Palette.generate(from: url)
            DispatchQueue.main.async {
                guard let palette else { return }
                self.palettes[url] = palette
                self.currentPalette = palette
                self.store.accent = settings.matchAccent ? Color(nsColor: palette.accent) : .accentColor
                guard export else { return }
                let folder = URL(fileURLWithPath: (settings.paletteFolder as NSString).expandingTildeInPath)
                if settings.exportPalette {
                    do { try palette.export(wallpaper: url, to: folder) } catch { NSLog("Palette export failed: \(error)") }
                }
                PostChangeHook.run(settings.postChangeCommand, wallpaper: url,
                                   colorsFolder: settings.exportPalette ? folder : nil)
            }
        }
    }

    // MARK: Launcher actions

    func cycleDisplay() {
        let count = NSScreen.screens.count
        guard count > 1 else { return }
        // nil (setting) → display 1 → … → display n → nil
        if let i = store.targetDisplay { store.targetDisplay = i + 1 < count ? i + 1 : nil } else { store.targetDisplay = 0 }
    }

    func cycleStyle() {
        let all = RingStyle.allCases
        settings.ringStyle = all[((all.firstIndex(of: settings.ringStyle) ?? 0) + 1) % all.count]
    }

    func toggleFavorite() {
        guard let wp = store.selected else { return }
        settings.toggleFavorite(wp.url)
        if store.tab == .favorites && store.filtered.isEmpty { store.tab = .all }
    }

    // MARK: Keyboard

    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let cmd = flags.contains(.command)
            let grid = self.settings.ringStyle == .grid
            let code = Int(event.keyCode)
            switch code {
            case kVK_LeftArrow: grid ? self.store.moveClamped(-1) : self.store.move(-1)
            case kVK_RightArrow, kVK_Tab:
                let d = flags.contains(.shift) ? -1 : 1
                grid ? self.store.moveClamped(d) : self.store.move(d)
            case kVK_UpArrow, kVK_DownArrow:
                let d = code == kVK_UpArrow ? -1 : 1
                if grid && !flags.contains(.option) { self.store.moveClamped(d * self.store.gridColumns) }
                else { self.store.switchTab(d) }
            case kVK_Home: self.store.selection = 0
            case kVK_End: self.store.selection = max(0, self.store.filtered.count - 1)
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if let wp = self.store.selected { self.apply(wp.url, keepOpen: flags.contains(.shift)) }
            case kVK_Escape:
                if self.store.query.isEmpty { self.hide() } else { self.store.query = "" }
            case kVK_ANSI_R where cmd: self.applyRandom()
            case kVK_ANSI_F where cmd: self.toggleFavorite()
            case kVK_ANSI_D where cmd: self.cycleDisplay()
            case kVK_ANSI_S where cmd: self.cycleStyle()
            case kVK_ANSI_G where cmd: self.openOnline()
            case kVK_ANSI_W where cmd: self.hide()
            case kVK_ANSI_Comma where cmd: self.openSettings()
            case kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9:
                guard cmd else { return event }
                let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
                let i = digits.firstIndex(of: code)!
                if i < NSScreen.screens.count { self.store.targetDisplay = i }
            default: return event
            }
            return nil
        }
    }

    func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            // The grid scrolls natively.
            if self.settings.ringStyle == .grid { return event }
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

        Publishers.CombineLatest3(settings.$folders, settings.$disabledImageTypes, settings.$sortOrder)
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.store.reload() }
            .store(in: &cancellables)

        Publishers.CombineLatest(settings.$blurRadius, settings.$livePreview)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in if self?.panel.isVisible == true { self?.applyBlur() } }
            .store(in: &cancellables)

        settings.$matchAccent
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                guard let self else { return }
                self.store.accent = on ? (self.currentPalette.map { Color(nsColor: $0.accent) } ?? .accentColor) : .accentColor
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(settings.$lightDarkPairs, settings.$animateGIFs, settings.$scaling)
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.engine.reapplyAll(onlyIfDifferent: false) }
            .store(in: &cancellables)

        Publishers.CombineLatest(settings.$showInDock, settings.$showInMenuBar)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.applyIconSettings() }
            .store(in: &cancellables)

        settings.$pauseVideosOnBattery
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { _ in LiveWallpaper.shared.updatePowerState() }
            .store(in: &cancellables)
    }

    @objc func openSettings() {
        if panel.isVisible { hide() }
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, store: store, app: self) { [weak self] in self?.show() }
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

    @objc func openOnline() {
        if panel.isVisible { hide() }
        if onlineWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: OnlineView(model: onlineModel)))
            window.title = "Get Wallpapers"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 960, height: 700))
            window.isReleasedWhenClosed = false
            window.center()
            onlineWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onlineWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Wallpaper")
        button.toolTip = "WallpaperLauncher – drop images here to add them"
        let drop = StatusDropView(button: button)
        drop.onDrop = { [weak self] urls in self?.importDropped(urls) }
        button.addSubview(drop)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func importDropped(_ urls: [URL]) {
        Task {
            let imported = await Importer.importFiles(urls)
            await MainActor.run {
                guard let last = imported.last else { return }
                self.store.reload()
                self.applyAutomatically(last)
            }
        }
    }

    /// Dock icon and menu bar icon can each be turned off; the shortcut always works.
    func applyIconSettings() {
        let policy: NSApplication.ActivationPolicy = settings.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            // Leaving the Dock deactivates the app; keep open windows in front.
            if policy == .accessory, settingsWindow?.isVisible == true { NSApp.activate(ignoringOtherApps: true) }
        }
        statusItem.isVisible = settings.showInMenuBar
    }

    /// The app menu shown while the app is active (only relevant with the Dock icon).
    func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = main.addItem(withTitle: "WallpaperLauncher", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "WallpaperLauncher")
        appMenu.addItem(withTitle: "About WallpaperLauncher", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide WallpaperLauncher", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit WallpaperLauncher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = main.addItem(withTitle: "Wallpaper", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "Wallpaper")
        fileMenu.addItem(withTitle: "Open Launcher", action: #selector(showFromMenu), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: "Next Wallpaper", action: #selector(nextWallpaper), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: "Random Wallpaper", action: #selector(applyRandom), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: "Get Wallpapers…", action: #selector(openOnline), keyEquivalent: "").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        // Standard edit commands so copy/paste works in text fields.
        let editItem = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        return main
    }

    /// Right-click menu of the Dock icon: same items as the menu bar icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        fillMenu(menu, includeQuit: false)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        fillMenu(menu, includeQuit: true)
    }

    func fillMenu(_ menu: NSMenu, includeQuit: Bool) {
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
        menu.addItem(withTitle: "Next Wallpaper", action: #selector(nextWallpaper), keyEquivalent: "")
        menu.addItem(withTitle: "Random Wallpaper", action: #selector(applyRandom), keyEquivalent: "")
        menu.addItem(withTitle: "Get Wallpapers…", action: #selector(openOnline), keyEquivalent: "")
        if LiveWallpaper.shared.isActive {
            menu.addItem(withTitle: "Stop Live Wallpaper", action: #selector(stopLive), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rescan (\(store.all.count) wallpapers)", action: #selector(reloadFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        if includeQuit {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    @objc func showFromMenu() { show() }
    @objc func reloadFromMenu() { store.reload() }
    @objc func checkForUpdates() { Updater.shared.check(userInitiated: true) }

    @objc func stopLive() {
        // Keeps the still frame as the desktop picture.
        LiveWallpaper.shared.stopAll()
    }

    // MARK: Debug snapshots

    func snapshotSettings(tab: Int, to path: String) {
        store.reload()
        let view = SettingsView(settings: settings, store: store, app: self, initialTab: tab) {}
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
