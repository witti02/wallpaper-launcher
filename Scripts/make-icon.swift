// Renders the app icon: a ring of tall wallpaper cards on a dark macOS squircle.
// Usage: swift Scripts/make-icon.swift <output.png>

import AppKit
import CoreGraphics

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: locations)!
}

// MARK: Squircle background (macOS icon grid: 824pt body, 100pt margin)

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
ctx.addPath(squircle)
ctx.setFillColor(color(0x0B0B1A))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
ctx.drawLinearGradient(gradient([color(0x2A1B4D), color(0x111127), color(0x07070F)], [0, 0.55, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Soft glow behind the ring.
ctx.drawRadialGradient(gradient([color(0xFF8A5B, 0.85), color(0xC04CFF, 0.38), color(0x000000, 0)], [0, 0.42, 1]),
                       startCenter: CGPoint(x: 512, y: 520), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 520), endRadius: 460, options: [])

// A few stars.
var seed: UInt64 = 7
func rand() -> Double {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(seed >> 33) / Double(1 << 31)
}
for _ in 0..<70 {
    let p = CGPoint(x: 100 + rand() * 824, y: 700 + rand() * 224)
    let r = 1 + rand() * 2.4
    ctx.setFillColor(color(0xFFFFFF, 0.15 + rand() * 0.45))
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
}

// MARK: Ring of cards (same projection as the app)

struct Wallpaper { let top: UInt32; let mid: UInt32; let bottom: UInt32; let hill: UInt32 }
let wallpapers: [Wallpaper] = [
    .init(top: 0x1D2B64, mid: 0x3A6EA5, bottom: 0x9BC5E8, hill: 0x14213D), // night blue
    .init(top: 0x0F3443, mid: 0x34E89E, bottom: 0xB7F8DB, hill: 0x0B2027), // aurora
    .init(top: 0x41295A, mid: 0xC0538B, bottom: 0xF6B48F, hill: 0x2F0743), // dusk
    .init(top: 0x2B1055, mid: 0xFF5F6D, bottom: 0xFFC371, hill: 0x1A0B2E), // sunset (front)
    .init(top: 0x4B6CB7, mid: 0x7FA7E0, bottom: 0xE0EAFC, hill: 0x182848), // morning
    .init(top: 0x134E5E, mid: 0x3FA58A, bottom: 0x71B280, hill: 0x0A2A32), // forest
    .init(top: 0x232526, mid: 0x5A5C5E, bottom: 0xA4A6A8, hill: 0x111213), // mono
]

let center = CGPoint(x: 512, y: 540)
let radius = 470.0
let camera = radius * 1.7
let cardW = 126.0, cardH = 390.0
let step = 21.0 * .pi / 180

struct Card { let corners: [CGPoint]; let mirror: [CGPoint]; let depth: Double; let wp: Wallpaper; let front: Bool; let scale: Double }

var cards: [Card] = []
for (i, wp) in wallpapers.enumerated() {
    let theta = Double(i - 3) * step
    let cx = radius * sin(theta), cz = radius * cos(theta) - radius
    let tx = cos(theta), tz = -sin(theta)
    func project(_ dx: Double, _ dy: Double) -> CGPoint {
        let x = cx + tx * dx, z = cz + tz * dx
        let s = camera / (camera - z)
        return CGPoint(x: center.x + x * s, y: center.y + dy * s)
    }
    let corners = [project(-cardW / 2, -cardH / 2), project(cardW / 2, -cardH / 2),
                   project(cardW / 2, cardH / 2), project(-cardW / 2, cardH / 2)]
    let mirror = [project(-cardW / 2, -cardH / 2 - 8), project(cardW / 2, -cardH / 2 - 8),
                  project(cardW / 2, -cardH / 2 - 8 - cardH * 0.4), project(-cardW / 2, -cardH / 2 - 8 - cardH * 0.4)]
    cards.append(Card(corners: corners, mirror: mirror, depth: -cz, wp: wp, front: i == 3, scale: camera / (camera - cz)))
}

// Reflections on the floor first, so cards overlap them.
for card in cards.sorted(by: { $0.depth > $1.depth }) {
    let m = CGMutablePath()
    m.addLines(between: card.mirror)
    m.closeSubpath()
    let top = card.mirror[0].y, bottom = card.mirror[3].y
    ctx.saveGState()
    ctx.addPath(m)
    ctx.clip()
    let a = card.front ? 0.45 : 0.3 * card.scale
    ctx.drawLinearGradient(gradient([color(card.wp.hill, a), color(card.wp.mid, a * 0.5), color(card.wp.mid, 0)], [0, 0.35, 1]),
                           start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
    ctx.restoreGState()
}

for card in cards.sorted(by: { $0.depth > $1.depth }) {
    let path = CGMutablePath()
    path.addLines(between: card.corners)
    path.closeSubpath()
    let minY = card.corners.map(\.y).min()!, maxY = card.corners.map(\.y).max()!
    let minX = card.corners.map(\.x).min()!, maxX = card.corners.map(\.x).max()!

    // Drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * card.scale), blur: 30 * card.scale, color: color(0x000000, 0.6))
    ctx.addPath(path)
    ctx.setFillColor(color(card.wp.top))
    ctx.fillPath()
    ctx.restoreGState()

    // Sky.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(card.wp.top), color(card.wp.mid), color(card.wp.bottom)], [0, 0.6, 1]),
                           start: CGPoint(x: 0, y: maxY), end: CGPoint(x: 0, y: minY), options: [])

    // Sun on the front card.
    if card.front {
        let sun = CGPoint(x: (minX + maxX) / 2, y: minY + (maxY - minY) * 0.42)
        ctx.drawRadialGradient(gradient([color(0xFFF1C1), color(0xFFD27F, 0.9), color(0xFFB36B, 0)], [0, 0.35, 1]),
                               startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 95, options: [])
    }

    // Mountains.
    let w = maxX - minX, h = maxY - minY
    let hills = CGMutablePath()
    hills.move(to: CGPoint(x: minX - 10, y: minY - 10))
    hills.addLine(to: CGPoint(x: minX - 10, y: minY + h * 0.30))
    hills.addLine(to: CGPoint(x: minX + w * 0.30, y: minY + h * 0.46))
    hills.addLine(to: CGPoint(x: minX + w * 0.52, y: minY + h * 0.33))
    hills.addLine(to: CGPoint(x: minX + w * 0.78, y: minY + h * 0.52))
    hills.addLine(to: CGPoint(x: maxX + 10, y: minY + h * 0.36))
    hills.addLine(to: CGPoint(x: maxX + 10, y: minY - 10))
    hills.closeSubpath()
    ctx.addPath(hills)
    ctx.setFillColor(color(card.wp.hill, 0.92))
    ctx.fillPath()

    // Glossy highlight.
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)]),
                           start: CGPoint(x: minX, y: maxY), end: CGPoint(x: minX + w * 0.6, y: maxY - h * 0.5), options: [])

    // Depth darkening.
    ctx.setFillColor(color(0x05050C, min(0.65, (1 - card.scale) * 1.4)))
    ctx.fill(CGRect(x: minX - 5, y: minY - 5, width: w + 10, height: h + 10))
    ctx.restoreGState()

    if card.front {
        ctx.addPath(path)
        ctx.setStrokeColor(color(0xFFFFFF, 0.95))
        ctx.setLineWidth(7)
        ctx.strokePath()
    }
}

ctx.restoreGState()

// Subtle inner border.
ctx.addPath(squircle)
ctx.setStrokeColor(color(0xFFFFFF, 0.08))
ctx.setLineWidth(3)
ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("✓ wrote \(out)")
