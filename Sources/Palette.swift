import AppKit

/// A 16-color terminal scheme plus an accent color, derived from a wallpaper (similar to pywal).
struct Palette {
    var colors: [NSColor] // color0…color15
    var accent: NSColor
    var background: NSColor { colors[0] }
    var foreground: NSColor { colors[15] }

    // MARK: Generation

    static func generate(from url: URL) -> Palette? {
        guard let cg = ImageLoader.cgImage(for: url, maxPixels: 256) else { return nil }
        let pixels = samplePixels(cg)
        guard pixels.count > 16 else { return nil }
        let clusters = kMeans(pixels, k: 8)
        return build(from: clusters)
    }

    private struct RGB { var r, g, b: Double }
    private struct Cluster { var color: RGB; var count: Int }

    private static func samplePixels(_ image: CGImage) -> [RGB] {
        let side = 64
        var data = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &data, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var result: [RGB] = []
        result.reserveCapacity(side * side)
        for i in stride(from: 0, to: data.count, by: 4) where data[i + 3] > 200 {
            result.append(RGB(r: Double(data[i]) / 255, g: Double(data[i + 1]) / 255, b: Double(data[i + 2]) / 255))
        }
        return result
    }

    private static func kMeans(_ pixels: [RGB], k: Int) -> [Cluster] {
        // Deterministic start: centers spread over the brightness range.
        let sorted = pixels.sorted { luma($0) < luma($1) }
        var centers = (0..<k).map { sorted[min(sorted.count - 1, ($0 * 2 + 1) * sorted.count / (k * 2))] }
        var counts = [Int](repeating: 0, count: k)
        for _ in 0..<12 {
            var sums = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: k)
            counts = [Int](repeating: 0, count: k)
            for p in pixels {
                var best = 0, bestDist = Double.infinity
                for (i, c) in centers.enumerated() {
                    let d = (p.r - c.r) * (p.r - c.r) + (p.g - c.g) * (p.g - c.g) + (p.b - c.b) * (p.b - c.b)
                    if d < bestDist { bestDist = d; best = i }
                }
                sums[best].r += p.r; sums[best].g += p.g; sums[best].b += p.b
                counts[best] += 1
            }
            for i in 0..<k where counts[i] > 0 {
                let n = Double(counts[i])
                centers[i] = RGB(r: sums[i].r / n, g: sums[i].g / n, b: sums[i].b / n)
            }
        }
        return zip(centers, counts).filter { $0.1 > 0 }.map { Cluster(color: $0.0, count: $0.1) }
    }

    private static func luma(_ c: RGB) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

    private static func nsColor(_ c: RGB) -> NSColor {
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    private static func build(from clusters: [Cluster]) -> Palette {
        let byLuma = clusters.sorted { luma($0.color) < luma($1.color) }
        let bg = nsColor(byLuma.first!.color).blended(withFraction: 0.55, of: .black)!
        let fg = nsColor(byLuma.last!.color).blended(withFraction: 0.65, of: .white)!

        // Six accent colors, readable on the dark background, ordered by hue.
        var accents = byLuma.dropFirst().map { nsColor($0.color) }
        if accents.isEmpty { accents = [fg] }
        while accents.count < 6 { accents.append(accents[accents.count % max(1, accents.count)]) }
        accents = Array(accents.prefix(6)).map { readable($0) }.sorted { $0.hueComponent < $1.hueComponent }

        var colors = [bg] + accents + [fg.blended(withFraction: 0.15, of: .gray)!]
        colors.append(bg.blended(withFraction: 0.3, of: .white)!)
        colors += accents.map { $0.blended(withFraction: 0.2, of: .white)! }
        colors.append(fg)

        // UI accent: the most vivid cluster, weighted a little by how much of the image it covers.
        let accent = clusters.max { score($0) < score($1) }.map { vivid(nsColor($0.color)) } ?? .controlAccentColor
        return Palette(colors: colors, accent: accent)
    }

    private static func score(_ c: Cluster) -> Double {
        let color = nsColor(c.color).usingColorSpace(.sRGB)!
        return color.saturationComponent * color.brightnessComponent * pow(Double(c.count), 0.3)
    }

    private static func readable(_ c: NSColor) -> NSColor {
        let s = c.usingColorSpace(.sRGB)!
        return NSColor(hue: s.hueComponent, saturation: min(1, s.saturationComponent * 1.15 + 0.1),
                       brightness: max(0.62, min(0.92, s.brightnessComponent + 0.15)), alpha: 1)
    }

    private static func vivid(_ c: NSColor) -> NSColor {
        let s = c.usingColorSpace(.sRGB)!
        return NSColor(hue: s.hueComponent, saturation: max(0.45, min(0.9, s.saturationComponent * 1.3)),
                       brightness: max(0.8, s.brightnessComponent), alpha: 1)
    }

    // MARK: Export

    /// Writes the scheme in several formats and runs the user's post-change command.
    func export(wallpaper: URL, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hex = colors.map(\.hex)
        let bg = background.hex, fg = foreground.hex
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]

        let json: [String: Any] = [
            "wallpaper": wallpaper.path,
            "accent": accent.hex,
            "special": ["background": bg, "foreground": fg, "cursor": fg],
            "colors": Dictionary(uniqueKeysWithValues: hex.enumerated().map { ("color\($0.offset)", $0.element) }),
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: folder.appendingPathComponent("colors.json"))

        var sh = "# Generated by WallpaperLauncher\nwallpaper='\(wallpaper.path)'\nbackground='\(bg)'\nforeground='\(fg)'\naccent='\(accent.hex)'\n"
        sh += hex.enumerated().map { "color\($0.offset)='\($0.element)'" }.joined(separator: "\n") + "\n"
        try sh.write(to: folder.appendingPathComponent("colors.sh"), atomically: true, encoding: .utf8)

        var css = ":root {\n  --wallpaper: url(\"file://\(wallpaper.path)\");\n  --background: \(bg);\n  --foreground: \(fg);\n  --accent: \(accent.hex);\n"
        css += hex.enumerated().map { "  --color\($0.offset): \($0.element);" }.joined(separator: "\n") + "\n}\n"
        try css.write(to: folder.appendingPathComponent("colors.css"), atomically: true, encoding: .utf8)

        var kitty = "background \(bg)\nforeground \(fg)\ncursor \(fg)\nselection_background \(hex[8])\n"
        kitty += hex.enumerated().map { "color\($0.offset) \($0.element)" }.joined(separator: "\n") + "\n"
        try kitty.write(to: folder.appendingPathComponent("colors-kitty.conf"), atomically: true, encoding: .utf8)

        var ghostty = "background = \(bg)\nforeground = \(fg)\ncursor-color = \(fg)\n"
        ghostty += hex.enumerated().map { "palette = \($0.offset)=\($0.element)" }.joined(separator: "\n") + "\n"
        try ghostty.write(to: folder.appendingPathComponent("colors-ghostty"), atomically: true, encoding: .utf8)

        var alacritty = "[colors.primary]\nbackground = \"\(bg)\"\nforeground = \"\(fg)\"\n\n[colors.normal]\n"
        alacritty += names.enumerated().map { "\($0.element) = \"\(hex[$0.offset])\"" }.joined(separator: "\n")
        alacritty += "\n\n[colors.bright]\n"
        alacritty += names.enumerated().map { "\($0.element) = \"\(hex[$0.offset + 8])\"" }.joined(separator: "\n") + "\n"
        try alacritty.write(to: folder.appendingPathComponent("colors-alacritty.toml"), atomically: true, encoding: .utf8)

        var xres = "*.background: \(bg)\n*.foreground: \(fg)\n"
        xres += hex.enumerated().map { "*.color\($0.offset): \($0.element)" }.joined(separator: "\n") + "\n"
        try xres.write(to: folder.appendingPathComponent("colors.Xresources"), atomically: true, encoding: .utf8)
    }
}

// MARK: - Post-change hook

enum PostChangeHook {
    /// Runs the user's shell command with `$WALLPAPER` (and `$WALLPAPER_COLORS` when exported) set.
    static func run(_ command: String, wallpaper: URL, colorsFolder: URL?) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", trimmed]
        var env = ProcessInfo.processInfo.environment
        env["WALLPAPER"] = wallpaper.path
        if let colorsFolder { env["WALLPAPER_COLORS"] = colorsFolder.appendingPathComponent("colors.json").path }
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { NSLog("Post-change command failed: \(error)") }
    }
}

extension NSColor {
    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}
