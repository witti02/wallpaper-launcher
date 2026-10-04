import AppKit
import Combine

/// Changes the wallpaper on a timer or by time of day.
final class Automation {
    private let settings = Settings.shared
    private let store: WallpaperStore
    private let apply: (URL) -> Void
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let defaults = UserDefaults.standard

    private var lastChange: Date {
        get { defaults.object(forKey: "automationLastChange") as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: "automationLastChange") }
    }
    private var lastSlot: String? {
        get { defaults.string(forKey: "automationLastSlot") }
        set { defaults.set(newValue, forKey: "automationLastSlot") }
    }
    private var sequenceIndex: Int {
        get { defaults.integer(forKey: "automationSequenceIndex") }
        set { defaults.set(newValue, forKey: "automationSequenceIndex") }
    }

    init(store: WallpaperStore, apply: @escaping (URL) -> Void) {
        self.store = store
        self.apply = apply
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 5

        // Re-evaluate right away when the configuration changes.
        Publishers.CombineLatest3(settings.$automation, settings.$timeSlots, settings.$intervalMinutes)
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.lastSlot = nil
                self?.tick()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.tick() }
    }

    func tick() {
        LiveWallpaper.shared.updatePowerState()
        switch settings.automation {
        case .off:
            break
        case .interval:
            if Date().timeIntervalSince(lastChange) >= Double(settings.intervalMinutes) * 60 { next() }
        case .timeOfDay:
            guard let slot = activeSlot(), !slot.path.isEmpty else { return }
            let key = slot.id.uuidString + slot.path
            if key != lastSlot, let url = pick(from: URL(fileURLWithPath: slot.path)) {
                lastSlot = key
                apply(url)
            }
        }
    }

    /// Next wallpaper from the rotation pool (also used by the "Next Wallpaper" menu item).
    func next() {
        var pool = store.all
        if settings.rotationPool == .favorites { pool = pool.filter { settings.isFavorite($0.url) } }
        guard !pool.isEmpty else { return }
        let url: URL
        if settings.rotationShuffle {
            let others = pool.filter { $0.url != store.current }
            url = (others.isEmpty ? pool : others).randomElement()!.url
        } else {
            sequenceIndex = (sequenceIndex + 1) % pool.count
            url = pool[sequenceIndex].url
        }
        lastChange = Date()
        apply(url)
    }

    /// The slot whose start time was most recently passed (wrapping around midnight).
    func activeSlot(at date: Date = Date()) -> TimeSlot? {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let sorted = settings.timeSlots.sorted { $0.minutesOfDay < $1.minutesOfDay }
        return sorted.last { $0.minutesOfDay <= now } ?? sorted.last
    }

    /// A slot can point to a single file or to a folder to pick a random wallpaper from.
    private func pick(from url: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        guard isDir.boolValue else { return url }
        let extensions = settings.enabledExtensions
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files.filter { extensions.contains($0.pathExtension.lowercased()) }.randomElement()
    }
}
