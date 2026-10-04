import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var store: WallpaperStore
    @StateObject private var tab: TabModel
    var onPreview: () -> Void

    init(settings: Settings, store: WallpaperStore, initialTab: Int = 0, onPreview: @escaping () -> Void) {
        self.settings = settings
        self.store = store
        self.onPreview = onPreview
        _tab = StateObject(wrappedValue: TabModel(selection: initialTab))
    }

    var body: some View {
        TabView(selection: $tab.selection) {
            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            FolderSettings(settings: settings, store: store)
                .tabItem { Label("Folders", systemImage: "folder") }.tag(1)
            AppearanceSettings(settings: settings, onPreview: onPreview)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }.tag(2)
        }
        .frame(width: 560, height: 560)
    }
}

final class TabModel: ObservableObject {
    @Published var selection: Int
    init(selection: Int) { self.selection = selection }
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
            Section("System") {
                Toggle("Launch at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                if let error = login.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                Text("macOS only changes the wallpaper of the current Space.")
                    .font(.caption).foregroundStyle(.secondary)
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

struct FolderSettings: View {
    @ObservedObject var settings: Settings
    @ObservedObject var store: WallpaperStore

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
                Button("Add Folder…", systemImage: "plus") { addFolder() }
            } header: {
                Text("Wallpaper folders")
            } footer: {
                HStack {
                    Text("\(store.all.count) wallpapers found")
                    Spacer()
                    Button("Rescan") { store.reload() }.controlSize(.small)
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("File types") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading) {
                    ForEach(ImageType.all) { type in
                        Toggle(type.label, isOn: Binding(
                            get: { settings.imageTypes.contains(type.id) },
                            set: { on in
                                if on { settings.imageTypes.insert(type.id) } else { settings.imageTypes.remove(type.id) }
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
        }
        .formStyle(.grouped)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { settings.addFolders(panel.urls) }
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
            Section("Background") {
                SliderRow(title: "Blur", value: $settings.blurRadius, range: 0...40, format: "%.0f")
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
            Section("Ring") {
                SliderRow(title: "Spacing", value: $settings.cardSpacing, range: 5...30, format: "%.0f°")
                SliderRow(title: "Radius", value: $settings.ringRadius, range: 0.35...1.5, format: "%.2f")
                Stepper("Visible cards: \(settings.visibleCards)", value: $settings.visibleCards, in: 3...31, step: 2)
                SliderRow(title: "Animation speed", value: $settings.animationSpeed, range: 0.4...2.5, format: "%.1f×")
                Toggle("Spin in when opening", isOn: $settings.spinIn)
            }
            Section("Overlay") {
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
