import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Renders the README demo GIF (`--render-demo out.gif`) from generated sample wallpapers,
/// so no personal images end up in the repository.
enum DemoRenderer {
    static let size = CGSize(width: 760, height: 428)

    @MainActor
    static func render(to path: String) {
        do {
            let settings = Settings.shared
            let saved = SettingsSnapshot(settings)
            settings.resetAppearance()
            settings.matchAccent = false
            settings.favorites = []

            let store = WallpaperStore()
            let samples = makeSampleWallpapers()
            store.all = samples.map(\.0)
            store.accent = Color(red: 1, green: 0.55, blue: 0.4)

            var frames: [CGImage] = []
            @MainActor func frame(_ background: (NSImage?, NSImage?, Double), opacity: Double = 1) {
                let view = DemoFrame(store: store, list: store.all, background: background, opacity: opacity)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                if let image = renderer.cgImage { frames.append(image) }
            }
            @MainActor func image(_ offset: Int) -> NSImage? {
                samples[((store.position + offset) % samples.count + samples.count) % samples.count].1
            }
            func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }

            @MainActor func steps(_ count: Int, framesPerStep: Int, hold: Int) {
                let step = settings.cardSpacing
                for _ in 0..<count {
                    for f in 1...framesPerStep {
                        let t = ease(Double(f) / Double(framesPerStep))
                        store.spin = -t * step
                        frame((image(0), image(1), t))
                    }
                    store.position += 1
                    store.spin = 0
                    for _ in 0..<hold { frame((image(0), nil, 0)) }
                }
            }

            // Spin in.
            settings.ringStyle = .ring
            store.position = 0
            for f in 0...16 {
                let t = ease(Double(f) / 16)
                store.spin = 40 * (1 - t)
                frame((image(0), nil, 0), opacity: t)
            }
            for _ in 0..<8 { frame((image(0), nil, 0)) }
            steps(4, framesPerStep: 9, hold: 5)

            // Carousel style.
            settings.ringStyle = .carousel
            for _ in 0..<8 { frame((image(0), nil, 0)) }
            steps(3, framesPerStep: 9, hold: 5)
            for _ in 0..<6 { frame((image(0), nil, 0)) }

            saved.restore(settings)
            let out = URL(fileURLWithPath: path)
            if !writeGIFWithFFmpeg(frames, to: out, fps: 20) { writeGIF(frames, to: out, delay: 0.05) }
            print("✓ wrote \(path) (\(frames.count) frames)")
            exit(0)
        }
    }

    /// ffmpeg builds an optimized palette with dithering, which avoids banding in gradients.
    private static func writeGIFWithFFmpeg(_ frames: [CGImage], to url: URL, fps: Int) -> Bool {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ffmpeg else { return false }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperLauncherDemoFrames-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (i, frame) in frames.enumerated() {
            let data = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])
            try? data?.write(to: dir.appendingPathComponent(String(format: "%04d.png", i)))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-loglevel", "error", "-y", "-framerate", String(fps), "-i", dir.appendingPathComponent("%04d.png").path,
                       "-vf", "split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a",
                       "-loop", "0", url.path]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func writeGIF(_ frames: [CGImage], to url: URL, delay: Double) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        let fileProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, fileProps)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(dest, frame, frameProps) }
        CGImageDestinationFinalize(dest)
    }

    // MARK: Sample wallpapers

    private struct Scene { let sky: [UInt32]; let mountains: [UInt32]; let sun: UInt32?; let stars: Bool }

    private static let scenes: [Scene] = [
        Scene(sky: [0x2B1055, 0xFF5F6D, 0xFFC371], mountains: [0x6B2D5C, 0x431C4C, 0x1A0B2E], sun: 0xFFF1C1, stars: false),
        Scene(sky: [0x0F2027, 0x203A43, 0x2C5364], mountains: [0x2E5266, 0x1B3A4B, 0x0B1D26], sun: nil, stars: true),
        Scene(sky: [0x0F3443, 0x34E89E, 0xB7F8DB], mountains: [0x1E6B5C, 0x124A40, 0x0B2027], sun: nil, stars: true),
        Scene(sky: [0x4B6CB7, 0x7FA7E0, 0xE0EAFC], mountains: [0x5C7AA8, 0x3A5683, 0x182848], sun: 0xFFFFFF, stars: false),
        Scene(sky: [0x41295A, 0xC0538B, 0xF6B48F], mountains: [0x8A3E6B, 0x5A2350, 0x2F0743], sun: 0xFFE3B3, stars: false),
        Scene(sky: [0x134E5E, 0x3FA58A, 0xC6E8B5], mountains: [0x2F7A5F, 0x1C5A47, 0x0A2A32], sun: 0xFFF6D5, stars: false),
        Scene(sky: [0x141E30, 0x243B55, 0x5B7DA8], mountains: [0x34507A, 0x22385A, 0x0E1A2E], sun: 0xE8F0FF, stars: true),
        Scene(sky: [0xF7971E, 0xFFD200, 0xFFF3B0], mountains: [0xC0691B, 0x8A4513, 0x4A230A], sun: 0xFFFFFF, stars: false),
        Scene(sky: [0x1F1C2C, 0x928DAB, 0xE9D5DA], mountains: [0x6E6788, 0x4A4563, 0x221F33], sun: nil, stars: true),
        Scene(sky: [0x000428, 0x004E92, 0x5FA8D3], mountains: [0x1F5F8B, 0x0F3D63, 0x02122B], sun: 0xDDEEFF, stars: true),
    ]

    private static func makeSampleWallpapers() -> [(Wallpaper, NSImage)] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperLauncherDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return scenes.enumerated().map { i, scene in
            let url = dir.appendingPathComponent(String(format: "sample-%02d.png", i))
            let cg = draw(scene, seed: UInt64(i + 1))
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            ThumbnailCache.shared.store(image, for: url)
            return (Wallpaper(url: url), image)
        }
    }

    private static func color(_ hex: UInt32, _ a: Double = 1) -> CGColor {
        CGColor(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255, alpha: a)
    }

    private static func draw(_ scene: Scene, seed: UInt64) -> CGImage {
        let w = 1280, h = 800
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var s = seed &* 0x9E3779B97F4A7C15
        func rand() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 33) / Double(1 << 31)
        }

        let sky = CGGradient(colorsSpace: space, colors: scene.sky.map { color($0) } as CFArray, locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h / 3), options: [.drawsAfterEndLocation])

        if scene.stars {
            for _ in 0..<160 {
                let r = 0.6 + rand() * 1.6
                ctx.setFillColor(color(0xFFFFFF, 0.3 + rand() * 0.6))
                ctx.fillEllipse(in: CGRect(x: rand() * Double(w), y: Double(h) * (0.45 + rand() * 0.55), width: r * 2, height: r * 2))
            }
        }
        if let sun = scene.sun {
            let c = CGPoint(x: Double(w) * (0.3 + rand() * 0.4), y: Double(h) * 0.52)
            let glow = CGGradient(colorsSpace: space, colors: [color(sun), color(sun, 0.5), color(sun, 0)] as CFArray,
                                  locations: [0, 0.25, 1])!
            ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: 260, options: [])
        }

        // Three mountain layers, farther ones higher and lighter.
        for (layer, hex) in scene.mountains.enumerated() {
            let base = Double(h) * (0.5 - Double(layer) * 0.12)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            var x = 0.0
            path.addLine(to: CGPoint(x: 0, y: base))
            while x < Double(w) {
                x += 80 + rand() * 140
                path.addLine(to: CGPoint(x: x, y: base + (rand() - 0.35) * 180))
            }
            path.addLine(to: CGPoint(x: Double(w), y: 0))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(color(hex))
            ctx.fillPath()
        }
        return ctx.makeImage()!
    }
}

/// One frame of the demo: background (cross-fading between two images), dimming, cards and the bottom bar.
private struct DemoFrame: View {
    @ObservedObject var store: WallpaperStore
    let list: [Wallpaper]
    let background: (NSImage?, NSImage?, Double)
    let opacity: Double

    var body: some View {
        let size = DemoRenderer.size
        ZStack {
            Color.black
            ZStack {
                if let a = background.0 { fill(a) }
                if let b = background.1 { fill(b).opacity(background.2) }
                Color.black.opacity(0.25)
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
            }
            .opacity(0.4 + 0.6 * opacity)
            CardsView(store: store, list: list, onApply: { _ in })
                .opacity(opacity)
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                    Text("Search wallpapers…").foregroundStyle(.white.opacity(0.45)).frame(width: 120, alignment: .leading)
                    Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 12)
                    Text(store.selected?.name ?? "").foregroundStyle(.white)
                    Text("\(store.selection + 1)/\(list.count)").foregroundStyle(.white.opacity(0.5))
                }
                .font(.system(size: 10))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(.black.opacity(0.45)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                .padding(.bottom, 22)
            }
            .opacity(opacity)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    private func fill(_ image: NSImage) -> some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            .frame(width: DemoRenderer.size.width, height: DemoRenderer.size.height).clipped()
    }
}

/// Saves and restores the appearance settings the demo changes, so rendering leaves no trace.
private struct SettingsSnapshot {
    private let values: [String: Any]
    private static let keys = ["ringStyle", "livePreview", "blurRadius", "dimming", "cardSize", "cardShape", "cornerRadius",
                               "cardSpacing", "ringRadius", "visibleCards", "sideDimming", "animationSpeed", "spinIn",
                               "showSearchBar", "showHints", "showTabs", "matchAccent", "favorites"]

    init(_ settings: Settings) {
        let d = UserDefaults.standard
        values = Dictionary(uniqueKeysWithValues: Self.keys.compactMap { k in d.object(forKey: k).map { (k, $0) } })
    }

    func restore(_ settings: Settings) {
        let d = UserDefaults.standard
        for key in Self.keys {
            if let v = values[key] { d.set(v, forKey: key) } else { d.removeObject(forKey: key) }
        }
        d.synchronize()
    }
}
