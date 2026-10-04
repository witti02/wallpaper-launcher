import AppKit
import SwiftUI

// MARK: - Building blocks

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

final class ImageModel: ObservableObject {
    @Published var image: NSImage?
}

struct ThumbView: View {
    let wallpaper: Wallpaper
    let isCurrent: Bool
    let isFavorite: Bool
    let size: CGSize
    let cornerRadius: Double
    @StateObject private var loader = ImageModel()

    var body: some View {
        // The synchronous cache lookup avoids a placeholder flash for already loaded thumbnails.
        let image = loader.image ?? ThumbnailCache.shared.cached(wallpaper.url)
        ZStack {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.white.opacity(0.06))
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()

            VStack {
                HStack(spacing: 4) {
                    if wallpaper.kind != .image {
                        Badge(symbol: wallpaper.kind == .video ? "play.fill" : "sparkles")
                    }
                    Spacer()
                    if isFavorite { Badge(symbol: "star.fill", tint: .yellow) }
                    if isCurrent { Badge(symbol: "checkmark", tint: .white) }
                }
                Spacer()
            }
            .padding(7)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: wallpaper.url) { loader.image = await ThumbnailCache.shared.image(for: wallpaper.url) }
    }
}

struct Badge: View {
    let symbol: String
    var tint: Color = .white

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
            .background(Circle().fill(.black.opacity(0.45)))
    }
}

/// Full-screen picture of the selected wallpaper behind the cards.
struct PreviewBackground: View {
    let url: URL?
    @StateObject private var loader = ImageModel()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = loader.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .id(url)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: url)
        }
        .task(id: url) {
            guard let url else { return }
            // Show the sharp thumbnail immediately, then swap in the large version.
            if let quick = ThumbnailCache.previews.cached(url) ?? ThumbnailCache.shared.cached(url) { loader.image = quick }
            try? await Task.sleep(nanoseconds: 90_000_000) // skip images that are only scrolled past
            guard !Task.isCancelled else { return }
            if let large = await ThumbnailCache.previews.image(for: url), !Task.isCancelled { loader.image = large }
        }
    }
}

// MARK: - Ring

/// Places a card on a cylinder seen from the front. The angle is animatable so cards
/// travel along the circle while the ring rotates instead of moving in a straight line.
struct RingSlot: ViewModifier, Animatable {
    var angle: Double // degrees, 0 = front
    let radius: Double
    let fadeAngle: Double // cards fade out when approaching this angle
    let step: Double
    let cornerRadius: Double
    let sideDimming: Double
    let highlight: Color

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
                    .strokeBorder(highlight.opacity(0.9 * front), lineWidth: 2.5)
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

/// Classic cover flow: the selected card faces you, the others are turned and stacked to the sides.
struct CarouselSlot: ViewModifier, Animatable {
    var offset: Double // slots away from the selected card
    let cardWidth: Double
    let fade: Double
    let cornerRadius: Double
    let sideDimming: Double
    let highlight: Color

    var animatableData: Double {
        get { offset }
        set { offset = newValue }
    }

    func body(content: Content) -> some View {
        let d: Double = abs(offset)
        let sign: Double = offset < 0 ? -1 : 1
        let near: Double = min(d, 1)
        let x: Double = sign * (near * cardWidth * 0.9 + max(0, d - 1) * cardWidth * 0.42)
        let front: Double = max(0, 1 - d * 1.6)
        let edge: Double = max(0, min(1, fade - d))
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(highlight.opacity(0.9 * front), lineWidth: 2.5)
            )
            .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            .rotation3DEffect(.degrees(sign * near * 58), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .scaleEffect(1 - near * 0.12)
            .brightness(-sideDimming * 0.3 * near - min(0.2, max(0, d - 1) * 0.03))
            .opacity(edge)
            .offset(x: x)
            .zIndex(-d)
    }
}

struct CardsView: View {
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
            switch settings.ringStyle {
            case .ring: ring(width: w, height: h, card: card)
            case .carousel: carousel(width: w, height: h, card: CGSize(width: card.width * 1.2, height: card.height * 1.2))
            case .grid: GridCards(store: store, list: list, width: w, card: card, onApply: onApply)
            }
        }
        .animation(.spring(response: 0.55 / settings.animationSpeed, dampingFraction: 0.82), value: store.position)
    }

    private var highlight: Color { settings.matchAccent ? store.accent : .white }

    private func ring(width w: Double, height h: Double, card: CGSize) -> some View {
        let radius: Double = w * settings.ringRadius
        let step: Double = settings.cardSpacing
        let n: Int = min(list.count, settings.visibleCards, Int(170 / step) | 1)
        let lo: Int = store.position - (n - 1) / 2
        let fade: Double = Double(n / 2 + 1) * step
        return ZStack {
            ForEach(Array(lo..<(lo + n)), id: \.self) { slot in
                let wp: Wallpaper = list[((slot % list.count) + list.count) % list.count]
                let angle: Double = Double(slot - store.position) * step + store.spin
                cardView(wp, card)
                    .modifier(RingSlot(angle: angle, radius: radius, fadeAngle: fade, step: step,
                                       cornerRadius: settings.cornerRadius, sideDimming: settings.sideDimming,
                                       highlight: highlight))
                    .onTapGesture(count: 2) { store.position = slot; onApply(wp.url) }
                    .onTapGesture { store.position = slot }
                    .transition(.opacity)
            }
        }
        .frame(width: w, height: h)
        .offset(y: -h * 0.02)
    }

    private func carousel(width w: Double, height h: Double, card: CGSize) -> some View {
        let n: Int = min(list.count, settings.visibleCards)
        let lo: Int = store.position - (n - 1) / 2
        let fade: Double = Double(n / 2) + 1
        return ZStack {
            ForEach(Array(lo..<(lo + n)), id: \.self) { slot in
                let wp: Wallpaper = list[((slot % list.count) + list.count) % list.count]
                let offset: Double = Double(slot - store.position) + store.spin / settings.cardSpacing
                cardView(wp, card)
                    .modifier(CarouselSlot(offset: offset, cardWidth: card.width, fade: fade,
                                           cornerRadius: settings.cornerRadius, sideDimming: settings.sideDimming,
                                           highlight: highlight))
                    .onTapGesture(count: 2) { store.position = slot; onApply(wp.url) }
                    .onTapGesture { store.position = slot }
                    .transition(.opacity)
            }
        }
        .frame(width: w, height: h)
        .offset(y: -h * 0.02)
    }

    private func cardView(_ wp: Wallpaper, _ size: CGSize) -> some View {
        ThumbView(wallpaper: wp, isCurrent: wp.url == store.current, isFavorite: settings.isFavorite(wp.url),
                  size: size, cornerRadius: settings.cornerRadius)
    }
}

// MARK: - Grid

struct GridCards: View {
    @ObservedObject var store: WallpaperStore
    @ObservedObject var settings = Settings.shared
    let list: [Wallpaper]
    let width: Double
    let card: CGSize
    var onApply: (URL) -> Void

    var body: some View {
        // Grid cells are smaller than ring cards so a good number fits on screen.
        let cell = CGSize(width: card.width * 0.72, height: card.height * 0.72)
        let spacing: Double = 18
        let usable: Double = min(width - 160, 1600)
        let columns: Int = max(2, Int((usable + spacing) / (cell.width + spacing)))
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell.width), spacing: spacing), count: columns),
                          spacing: spacing) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, wp in
                        let selected = i == store.selection
                        ThumbView(wallpaper: wp, isCurrent: wp.url == store.current, isFavorite: settings.isFavorite(wp.url),
                                  size: cell, cornerRadius: settings.cornerRadius)
                            .overlay(
                                RoundedRectangle(cornerRadius: settings.cornerRadius, style: .continuous)
                                    .strokeBorder(settings.matchAccent ? store.accent : .white, lineWidth: selected ? 3 : 0)
                            )
                            .scaleEffect(selected ? 1.06 : 1)
                            .brightness(selected ? 0 : -settings.sideDimming * 0.35)
                            .shadow(color: .black.opacity(selected ? 0.55 : 0.3), radius: selected ? 16 : 6, y: 6)
                            .zIndex(selected ? 1 : 0)
                            .id(wp.id)
                            .onTapGesture(count: 2) { store.selection = i; onApply(wp.url) }
                            .onTapGesture { store.selection = i }
                    }
                }
                .padding(.vertical, 120)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                store.gridColumns = columns
                if let id = store.selected?.id { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: columns) { _, new in store.gridColumns = new }
            .onChange(of: store.position) { _, _ in
                guard let id = store.selected?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.position)
    }
}

// MARK: - Launcher

struct LauncherView: View {
    @ObservedObject var store: WallpaperStore
    @ObservedObject var settings = Settings.shared
    var onApply: (URL) -> Void
    var onDismiss: () -> Void
    var onCycleDisplay: () -> Void
    var onCycleStyle: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let list = store.filtered
        ZStack {
            ZStack {
                if settings.livePreview {
                    Color.black
                    PreviewBackground(url: store.selected?.url)
                } else if store.needsFallbackBlur && settings.blurRadius > 0 {
                    VisualEffect(material: .fullScreenUI).opacity(min(1, settings.blurRadius / 25))
                }
                Color.black.opacity(settings.dimming)
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
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
                CardsView(store: store, list: list, onApply: onApply)
            }

            VStack(spacing: 8) {
                if settings.showTabs && store.tabs.count > 1 { tabBar.padding(.top, 44) }
                Spacer()
                if settings.showSearchBar { bottomBar }
                if settings.showHints {
                    Text("←→ select   ↑↓ folder   ↩ apply   ⌘F favorite   ⌘D display   ⌘S style   ⌘G online   ⌘R random   ⌘, settings   esc close")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.bottom, 44)
        }
        .tint(store.accent)
        .environment(\.colorScheme, .dark)
        .onAppear { searchFocused = true }
        .onChange(of: store.focusToken) { _, _ in searchFocused = true }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(store.tabs, id: \.self) { tab in
                let active = tab == store.tab
                Button {
                    store.tab = tab
                } label: {
                    HStack(spacing: 5) {
                        if tab == .favorites { Image(systemName: "star.fill").font(.system(size: 10)) }
                        Text(tab.title).font(.system(size: 12, weight: active ? .semibold : .regular))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(active ? store.accent.opacity(0.85) : .clear))
                    .foregroundStyle(active ? .white : .white.opacity(0.75))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(VisualEffect())
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private var bottomBar: some View {
        let list = store.filtered
        let selected = store.selected
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search wallpapers…", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .frame(width: 180)
                .focused($searchFocused)
            divider
            if let selected {
                if settings.isFavorite(selected.url) {
                    Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.yellow)
                }
                if settings.lightDarkPairs && WallpaperEngine.hasVariant(selected.url) {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 11)).help("Has a light/dark pair")
                }
            }
            Text(selected?.name ?? "–")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
            Text("\(list.isEmpty ? 0 : store.selection + 1)/\(list.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            divider
            Button(action: onCycleDisplay) {
                Label(displayLabel, systemImage: "display").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Display to apply to (⌘D)")
            Button(action: onCycleStyle) {
                Image(systemName: settings.ringStyle.symbol).font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Style: \(settings.ringStyle.label) (⌘S)")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(VisualEffect())
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 16)
    }

    private var displayLabel: String {
        guard let i = store.targetDisplay, let screen = NSScreen.screens[safe: i] else {
            return NSScreen.screens.count > 1 ? settings.displayTarget.label : "Display"
        }
        return "\(i + 1) · \(screen.localizedName)"
    }
}
