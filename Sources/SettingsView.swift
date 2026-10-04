import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

final class TabModel: ObservableObject {
    @Published var selection: Int
    init(selection: Int) { self.selection = selection }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var store: WallpaperStore
    @ObservedObject var app: AppDelegate
    @StateObject private var tab: TabModel
    var onPreview: () -> Void

    init(settings: Settings, store: WallpaperStore, app: AppDelegate, initialTab: Int = 0, onPreview: @escaping () -> Void) {
        self.settings = settings
        self.store = store
        self.app = app
        self.onPreview = onPreview
        _tab = StateObject(wrappedValue: TabModel(selection: initialTab))
    }

    var body: some View {
        TabView(selection: $tab.selection) {
            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            FolderSettings(settings: settings, store: store, onOpenOnline: { app.openOnline() })
                .tabItem { Label("Folders", systemImage: "folder") }.tag(1)
            AppearanceSettings(settings: settings, onPreview: onPreview)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }.tag(2)
            AutomationSettings(settings: settings, onNext: { app.nextWallpaper() })
                .tabItem { Label("Automation", systemImage: "clock.arrow.2.circlepath") }.tag(3)
            ColorSettings(settings: settings, app: app)
                .tabItem { Label("Colors", systemImage: "swatchpalette") }.tag(4)
        }
        .frame(width: 600, height: 620)
    }
}

// MARK: - General

final class LoginItemModel: ObservableObject {
    @Published var enabled = SMAppService.mainApp.status == .enabled
    @Published var error: String?

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "\(error.localizedDescription) The app must be in /Applications or ~/Applications."
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}

struct GeneralSettings: View {
    @ObservedObject var settings: Settings
    @StateObject private var login = LoginItemModel()

    var body: some View {
        Form {
            Section("Shortcut") {
                LabeledContent("Open launcher") { HotkeyRecorder(settings: settings) }
            }
            Section("Applying wallpapers") {
                Picker("Apply to", selection: $settings.displayTarget) {
                    ForEach(DisplayTarget.allCases) { Text($0.label).tag($0) }
                }
                Picker("Scaling", selection: $settings.scaling) {
                    ForEach(WallpaperScaling.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Close launcher after applying", isOn: $settings.closeOnApply)
                Toggle("Start at the current wallpaper", isOn: $settings.startAtCurrent)
            }
            Section {
                Toggle("Use the same wallpaper on all Spaces", isOn: $settings.allSpaces)
                Toggle("Switch light/dark pairs with the system appearance", isOn: $settings.lightDarkPairs)
            } header: {
                Text("Spaces & appearance")
            } footer: {
                Text("macOS only changes the current Space, so the app re-applies your wallpaper when you switch Spaces. Light/dark pairs are files named like `mountain-light.jpg` and `mountain-dark.jpg` (also `_light`/`_dark` or `day`/`night`) in the same folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Live wallpapers") {
                Toggle("Play animated GIFs", isOn: $settings.animateGIFs)
                Toggle("Pause videos on battery power", isOn: $settings.pauseVideosOnBattery)
                Text("Videos (MP4, MOV) and GIFs play muted behind your desktop icons while the app is running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("System") {
                Toggle("Launch at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                if let error = login.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show icon in the Dock", isOn: $settings.showInDock)
                Toggle("Show icon in the menu bar", isOn: $settings.showInMenuBar)
                if !settings.showInDock && !settings.showInMenuBar {
                    Text("Without icons, open the launcher with \(settings.hotkeyDisplay) and the settings with ⌘, inside it.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Check for updates automatically", isOn: $settings.checkForUpdates)
                LabeledContent("Version \(Updater.shared.currentVersion)") {
                    Button("Check Now") { Updater.shared.check(userInitiated: true) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcut recorder

final class HotkeyRecorderModel: ObservableObject {
    @Published var recording = false
    private var monitor: Any?

    func start(_ settings: Settings) {
        guard !recording else { return }
        recording = true
        settings.isRecordingHotkey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = Int(event.keyCode)
            if code == kVK_Escape {
                self?.stop(settings)
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods = 0
            if flags.contains(.command) { mods |= cmdKey }
            if flags.contains(.option) { mods |= optionKey }
            if flags.contains(.control) { mods |= controlKey }
            if flags.contains(.shift) { mods |= shiftKey }
            // Require a real modifier so normal typing is never swallowed (function keys are fine alone).
            guard mods & (cmdKey | optionKey | controlKey) != 0 || Settings.isFunctionKey(code) else {
                NSSound.beep()
                return nil
            }
            settings.hotkeyKeyCode = code
            settings.hotkeyModifiers = mods
            settings.hotkeyKeyName = Settings.specialKeyNames[code]
                ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
            self?.stop(settings)
            return nil
        }
    }

    func stop(_ settings: Settings) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        settings.isRecordingHotkey = false
    }
}

struct HotkeyRecorder: View {
    @ObservedObject var settings: Settings
    @StateObject private var model = HotkeyRecorderModel()

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.recording ? model.stop(settings) : model.start(settings)
            } label: {
                Text(model.recording ? "Press shortcut…" : settings.hotkeyDisplay)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(model.recording ? .accentColor : nil)
            if model.recording {
                Text("esc to cancel").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { model.stop(settings) }
    }
}

// MARK: - Folders

enum FilePicker {
    static func choose(folders: Bool, files: Bool, multiple: Bool = false, prompt: String = "Choose") -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders
        panel.canChooseFiles = files
        panel.allowsMultipleSelection = multiple
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.urls : []
    }
}

struct FolderSettings: View {
    @ObservedObject var settings: Settings
    @ObservedObject var store: WallpaperStore
    var onOpenOnline: () -> Void

    var body: some View {
        Form {
            Section {
                if settings.folders.isEmpty {
                    Text("No folders yet. Add one to get started.").foregroundStyle(.secondary)
                }
                ForEach($settings.folders) { $folder in
                    FolderRow(folder: $folder) {
                        settings.folders.removeAll { $0.path == folder.path }
                    }
                }
                Button("Add Folder…", systemImage: "plus") {
                    settings.addFolders(FilePicker.choose(folders: true, files: false, multiple: true, prompt: "Add"))
                }
            } header: {
                Text("Wallpaper folders")
            } footer: {
                HStack {
                    Text("\(store.all.count) wallpapers found · \(settings.favorites.count) favorites")
                    Spacer()
                    Button("Rescan") { store.reload() }.controlSize(.small)
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("File types") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading) {
                    ForEach(ImageType.all) { type in
                        Toggle(type.label, isOn: Binding(
                            get: { !settings.disabledImageTypes.contains(type.id) },
                            set: { on in
                                if on { settings.disabledImageTypes.remove(type.id) } else { settings.disabledImageTypes.insert(type.id) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }

            Section("Order") {
                Picker("Sort wallpapers by", selection: $settings.sortOrder) {
                    ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                LabeledContent("Save to") {
                    HStack {
                        Text(settings.downloadFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Change…") {
                            if let url = FilePicker.choose(folders: true, files: false).first {
                                settings.downloadFolder = url.path
                            }
                        }
                    }
                }
                Button("Get Wallpapers Online…", systemImage: "globe", action: onOpenOnline)
            } header: {
                Text("Downloads & imports")
            } footer: {
                Text("Wallpapers from the online browser and images dropped on the menu bar icon are saved here.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !settings.favorites.isEmpty {
                Section("Favorites") {
                    Button("Clear All Favorites", role: .destructive) { settings.favorites = [] }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct FolderRow: View {
    @Binding var folder: WallpaperFolder
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $folder.enabled).labelsHidden().toggleStyle(.checkbox)
            Image(systemName: FileManager.default.fileExists(atPath: folder.path) ? "folder.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(FileManager.default.fileExists(atPath: folder.path) ? Color.accentColor : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.url.lastPathComponent).fontWeight(.medium)
                Text(folder.displayPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .opacity(folder.enabled ? 1 : 0.5)
            Spacer()
            Toggle("Subfolders", isOn: $folder.recursive).toggleStyle(.checkbox).controlSize(.small)
            Button { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless).help("Show in Finder")
            Button(action: onRemove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).help("Remove folder")
        }
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @ObservedObject var settings: Settings
    var onPreview: () -> Void

    var body: some View {
        Form {
            Section("Style") {
                Picker("Layout", selection: $settings.ringStyle) {
                    ForEach(RingStyle.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Live preview of the selected wallpaper", isOn: $settings.livePreview)
            }
            Section("Background") {
                SliderRow(title: "Blur", value: $settings.blurRadius, range: 0...40, format: "%.0f")
                    .disabled(settings.livePreview)
                SliderRow(title: "Dimming", value: $settings.dimming, range: 0...0.8, format: "%.0f%%", scale: 100)
            }
            Section("Cards") {
                Picker("Shape", selection: $settings.cardShape) {
                    ForEach(CardShape.allCases) { Text($0.label).tag($0) }
                }
                SliderRow(title: "Size", value: $settings.cardSize, range: 0.25...0.75, format: "%.0f%%", scale: 100)
                SliderRow(title: "Corner radius", value: $settings.cornerRadius, range: 0...24, format: "%.0f")
                SliderRow(title: "Side card darkening", value: $settings.sideDimming, range: 0...1, format: "%.0f%%", scale: 100)
            }
            Section("Ring & carousel") {
                SliderRow(title: "Spacing", value: $settings.cardSpacing, range: 5...30, format: "%.0f°")
                SliderRow(title: "Ring radius", value: $settings.ringRadius, range: 0.35...1.5, format: "%.2f")
                Stepper("Visible cards: \(settings.visibleCards)", value: $settings.visibleCards, in: 3...31, step: 2)
                SliderRow(title: "Animation speed", value: $settings.animationSpeed, range: 0.4...2.5, format: "%.1f×")
                Toggle("Spin in when opening", isOn: $settings.spinIn)
                Toggle("Haptic feedback when scrolling on the trackpad", isOn: $settings.hapticFeedback)
            }
            Section("Overlay") {
                Toggle("Show folder tabs", isOn: $settings.showTabs)
                Toggle("Show search bar", isOn: $settings.showSearchBar)
                Toggle("Show keyboard hints", isOn: $settings.showHints)
            }
            Section {
                HStack {
                    Button("Reset to Defaults") { settings.resetAppearance() }
                    Spacer()
                    Button("Preview Launcher", action: onPreview).buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var scale: Double = 1

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range)
                Text(String(format: format, value * scale))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

// MARK: - Automation

struct AutomationSettings: View {
    @ObservedObject var settings: Settings
    var onNext: () -> Void

    private let intervals = [5, 10, 15, 30, 60, 120, 240, 720, 1440]

    var body: some View {
        Form {
            Section {
                Picker("Change wallpaper automatically", selection: $settings.automation) {
                    ForEach(AutomationMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if settings.automation == .interval {
                Section("Rotation") {
                    Picker("Every", selection: $settings.intervalMinutes) {
                        ForEach(intervals, id: \.self) { Text(Self.label(minutes: $0)).tag($0) }
                    }
                    Picker("From", selection: $settings.rotationPool) {
                        ForEach(RotationPool.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Shuffle", isOn: $settings.rotationShuffle)
                    Button("Next Wallpaper Now", action: onNext)
                }
            }

            if settings.automation == .timeOfDay {
                Section {
                    ForEach($settings.timeSlots) { $slot in
                        TimeSlotRow(slot: $slot) { settings.timeSlots.removeAll { $0.id == slot.id } }
                    }
                    Button("Add Time", systemImage: "plus") {
                        settings.timeSlots.append(TimeSlot(name: "New", hour: 12))
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    Text("Each time picks a wallpaper file, or a random one from a folder, and applies it from that time on.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if settings.automation == .off {
                Section {
                    Text("Pick “Change every…” to rotate through your wallpapers, or “Time of day” to show different wallpapers in the morning, during the day, in the evening and at night.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    static func label(minutes: Int) -> String {
        switch minutes {
        case ..<60: "\(minutes) minutes"
        case 60: "hour"
        case 1440: "day"
        default: "\(minutes / 60) hours"
        }
    }
}

struct TimeSlotRow: View {
    @Binding var slot: TimeSlot
    var onRemove: () -> Void

    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: Date()) ?? Date() },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                slot.hour = c.hour ?? 0
                slot.minute = c.minute ?? 0
            })
    }

    var body: some View {
        HStack(spacing: 10) {
            TextField("Name", text: $slot.name).frame(width: 90)
            DatePicker("", selection: time, displayedComponents: .hourAndMinute).labelsHidden()
            Text(slot.displayPath)
                .font(.caption).foregroundStyle(slot.path.isEmpty ? .orange : .secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose…") {
                if let url = FilePicker.choose(folders: true, files: true).first { slot.path = url.path }
            }
            .controlSize(.small)
            Button(action: onRemove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
        }
    }
}

// MARK: - Colors

struct ColorSettings: View {
    @ObservedObject var settings: Settings
    @ObservedObject var app: AppDelegate

    private var folderURL: URL { URL(fileURLWithPath: (settings.paletteFolder as NSString).expandingTildeInPath) }

    var body: some View {
        Form {
            Section("Current wallpaper") {
                if let palette = app.currentPalette {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            ForEach(0..<8, id: \.self) { Swatch(color: palette.colors[$0]) }
                        }
                        HStack(spacing: 4) {
                            ForEach(8..<16, id: \.self) { Swatch(color: palette.colors[$0]) }
                        }
                        HStack(spacing: 6) {
                            Swatch(color: palette.accent)
                            Text("Accent \(palette.accent.hex)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No palette yet – apply a wallpaper first.").foregroundStyle(.secondary)
                }
                Toggle("Tint the launcher with the wallpaper's accent color", isOn: $settings.matchAccent)
            }

            Section {
                Toggle("Export a color scheme when the wallpaper changes", isOn: $settings.exportPalette)
                LabeledContent("Folder") {
                    HStack {
                        Text(settings.paletteFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Change…") {
                            if let url = FilePicker.choose(folders: true, files: false).first { settings.paletteFolder = url.path }
                        }
                        Button { NSWorkspace.shared.open(folderURL) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Color scheme (like pywal)")
            } footer: {
                Text("Writes colors.json, colors.sh, colors.css, colors.Xresources, colors-kitty.conf, colors-ghostty and colors-alacritty.toml. Include them in your terminal or editor config.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Command", text: $settings.postChangeCommand, prompt: Text("e.g. kitty +kitten themes --reload-in=all"))
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Run after every change")
            } footer: {
                Text("Runs in zsh with $WALLPAPER (the image path) and $WALLPAPER_COLORS (colors.json, if exported) set.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct Swatch: View {
    let color: NSColor
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(nsColor: color))
            .frame(width: 28, height: 28)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.15)))
            .help(color.hex)
    }
}
