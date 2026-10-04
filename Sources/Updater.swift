import AppKit

/// Checks GitHub releases for a newer version and replaces the app in place.
final class Updater {
    static let shared = Updater()
    static let repository = "witti02/wallpaper-launcher"

    private let defaults = UserDefaults.standard
    private var isChecking = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let html_url: URL
        let body: String?
        let assets: [Asset]
        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    }

    /// Automatic check, at most once a day.
    func checkInBackground() {
        guard Settings.shared.checkForUpdates else { return }
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
                var request = URLRequest(url: url)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: request)
                let release = try JSONDecoder().decode(Release.self, from: data)
                await MainActor.run { self.defaults.set(Date(), forKey: "lastUpdateCheck") }

                if Self.isNewer(release.version, than: currentVersion) {
                    await MainActor.run { self.offer(release) }
                } else if userInitiated {
                    await MainActor.run {
                        self.alert("You're up to date", "WallpaperLauncher \(self.currentVersion) is the latest version.")
                    }
                }
            } catch {
                if userInitiated {
                    await MainActor.run { self.alert("Could not check for updates", error.localizedDescription) }
                }
            }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = pa[safe: i] ?? 0, y = pb[safe: i] ?? 0
            if x != y { return x > y }
        }
        return false
    }

    private func offer(_ release: Release) {
        let a = NSAlert()
        a.messageText = "WallpaperLauncher \(release.version) is available"
        var notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 700 { notes = String(notes.prefix(700)) + "…" }
        a.informativeText = "You have version \(currentVersion).\n\n\(notes)"
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "View Release")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
                NSWorkspace.shared.open(release.html_url)
                return
            }
            install(from: asset.browser_download_url, releasePage: release.html_url)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.html_url)
        default:
            break
        }
    }

    private func install(from zip: URL, releasePage: URL) {
        Task {
            do {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperLauncherUpdate-\(UUID().uuidString)")
                let archive = try await Downloader.download(zip, to: temp, fileName: "update.zip")
                try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, temp.path])
                let newApp = temp.appendingPathComponent("WallpaperLauncher.app")
                guard let bundle = Bundle(url: newApp),
                      bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                    throw NSError(domain: "Updater", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The downloaded file is not a WallpaperLauncher app."])
                }
                let current = Bundle.main.bundleURL
                guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
                    throw NSError(domain: "Updater", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "No permission to replace \(current.path)."])
                }
                await MainActor.run { self.relaunch(replacing: current, with: newApp) }
            } catch {
                await MainActor.run {
                    let a = NSAlert(error: error)
                    a.messageText = "Update failed"
                    a.addButton(withTitle: "OK")
                    a.addButton(withTitle: "Download Manually")
                    if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(releasePage) }
                }
            }
        }
    }

    /// Swaps the app bundle once this process has quit, then starts the new version.
    private func relaunch(replacing app: URL, with newApp: URL) {
        let script = """
        while kill -0 "$3" 2>/dev/null; do sleep 0.2; done
        rm -rf "$1.old"
        if mv "$1" "$1.old" && mv "$2" "$1"; then rm -rf "$1.old"; else mv "$1.old" "$1"; fi
        xattr -dr com.apple.quarantine "$1" 2>/dev/null
        open "$1"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "updater", app.path, newApp.path, String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            alert("Update failed", error.localizedDescription)
        }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "Updater", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) failed"])
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
