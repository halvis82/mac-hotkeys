import Cocoa

/// Draws the switcher row: one tile per fullscreen window, one per desktop Space.
final class SwitcherView: NSView {
    var tiles: [Tile] = []
    var selected = 0
    /// Which window inside a desktop tile the arrow keys have picked, keyed by Space id.
    var desktopSelection: [UInt64: Int] = [:]
    var thumbnails: [CGWindowID: NSImage] = [:]
    var desktopPreviews: [UInt64: NSImage] = [:]

    static let tileHeight: CGFloat = 132
    static let gap: CGFloat = 14
    static let padding: CGFloat = 20
    static let labelHeight: CGFloat = 26
    static let corner: CGFloat = 10

    private(set) var tileWidth: CGFloat = 208

    /// Tiles shrink rather than overflow when there are a lot of windows, the same way the
    /// system switcher shrinks its icons.
    func layoutSize(maxWidth: CGFloat) -> NSSize {
        let count = max(tiles.count, 1)
        tileWidth = 208
        var width = Self.padding * 2 + CGFloat(count) * tileWidth + CGFloat(count - 1) * Self.gap
        if width > maxWidth {
            let available = maxWidth - Self.padding * 2 - CGFloat(count - 1) * Self.gap
            tileWidth = max(96, available / CGFloat(count))
            width = Self.padding * 2 + CGFloat(count) * tileWidth + CGFloat(count - 1) * Self.gap
        }
        return NSSize(width: width,
                      height: Self.padding * 2 + Self.tileHeight + Self.labelHeight)
    }

    private func tileRect(_ index: Int) -> NSRect {
        NSRect(x: Self.padding + CGFloat(index) * (tileWidth + Self.gap),
               y: Self.padding + Self.labelHeight,
               width: tileWidth,
               height: Self.tileHeight)
    }

    /// The window that would be activated right now, which is what the label describes and
    /// what committing the switcher acts on.
    func currentWindow() -> WindowInfo? {
        guard selected < tiles.count else { return nil }
        let tile = tiles[selected]
        switch tile {
        case .window(_, let window):
            return window
        case .desktop(let space, let windows):
            let index = desktopSelection[space.id] ?? 0
            return windows.indices.contains(index) ? windows[index] : windows.first
        }
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high

        for (index, tile) in tiles.enumerated() {
            let rect = tileRect(index)
            if index == selected { drawSelection(around: rect) }
            drawThumbnail(for: tile, in: rect)
            switch tile {
            case .window(_, let window):
                drawAppIcon(window.icon, at: rect, highlighted: false)
            case .desktop(let space, let windows):
                drawIconGrid(windows,
                             in: rect,
                             selectedIndex: index == selected ? (desktopSelection[space.id] ?? 0) : -1)
            }
        }

        drawLabel()
    }

    private func drawSelection(around rect: NSRect) {
        let outer = rect.insetBy(dx: -8, dy: -8)
        let path = NSBezierPath(roundedRect: outer, xRadius: Self.corner + 5, yRadius: Self.corner + 5)
        NSColor.white.withAlphaComponent(0.22).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawThumbnail(for tile: Tile, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.corner, yRadius: Self.corner)
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()

        let image: NSImage?
        switch tile {
        case .window(_, let window): image = thumbnails[window.id]
        case .desktop(let space, _): image = desktopPreviews[space.id]
        }

        if let image = image {
            // Aspect fill so tiles read as uniform cards instead of letterboxed strips.
            let scale = max(rect.width / image.size.width, rect.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
            image.draw(in: NSRect(origin: origin, size: size),
                       from: .zero,
                       operation: .sourceOver,
                       fraction: 1.0)
        } else {
            // Thumbnails arrive asynchronously, so tiles start as plain cards.
            NSColor.white.withAlphaComponent(0.08).setFill()
            path.fill()
        }

        NSGraphicsContext.current?.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawAppIcon(_ icon: NSImage?, at rect: NSRect, highlighted: Bool) {
        guard let icon = icon else { return }
        let size: CGFloat = min(42, rect.width * 0.28)
        let iconRect = NSRect(x: rect.minX + 7, y: rect.minY + 7, width: size, height: size)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        icon.draw(in: iconRect)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// Desktop tiles show every window on that Space as an icon, in the order the arrow keys
    /// step through them, laid over the desktop preview.
    private func drawIconGrid(_ windows: [WindowInfo], in rect: NSRect, selectedIndex: Int) {
        guard !windows.isEmpty else { return }
        let iconSize: CGFloat = min(38, rect.width / 5.2)
        let spacing: CGFloat = 7
        let perRow = max(1, min(windows.count, Int((rect.width - 16) / (iconSize + spacing))))
        let rows = Int(ceil(Double(windows.count) / Double(perRow)))
        let gridHeight = CGFloat(rows) * iconSize + CGFloat(rows - 1) * spacing

        for (index, window) in windows.enumerated() {
            let row = index / perRow
            let column = index % perRow
            let itemsInRow = min(perRow, windows.count - row * perRow)
            let rowWidth = CGFloat(itemsInRow) * iconSize + CGFloat(itemsInRow - 1) * spacing
            let x = rect.midX - rowWidth / 2 + CGFloat(column) * (iconSize + spacing)
            let y = rect.midY + gridHeight / 2 - CGFloat(row + 1) * iconSize - CGFloat(row) * spacing
            let iconRect = NSRect(x: x, y: y, width: iconSize, height: iconSize)

            if index == selectedIndex {
                let ring = NSBezierPath(roundedRect: iconRect.insetBy(dx: -4, dy: -4), xRadius: 8, yRadius: 8)
                NSColor.white.withAlphaComponent(0.85).setFill()
                ring.fill()
            } else {
                let backing = NSBezierPath(roundedRect: iconRect.insetBy(dx: -3, dy: -3), xRadius: 7, yRadius: 7)
                NSColor.black.withAlphaComponent(0.35).setFill()
                backing.fill()
            }
            window.icon?.draw(in: iconRect,
                              from: .zero,
                              operation: .sourceOver,
                              fraction: window.isMinimized ? 0.55 : 1.0)
        }
    }

    private func drawLabel() {
        guard let window = currentWindow() else { return }
        let text = window.title.isEmpty ? window.appName : "\(window.appName) - \(window.title)"
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .paragraphStyle: style,
        ]
        let rect = NSRect(x: Self.padding,
                          y: Self.padding * 0.4,
                          width: bounds.width - Self.padding * 2,
                          height: Self.labelHeight)
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}

/// The floating panel itself. It must never take focus, or the app we are switching away from
/// would stop being frontmost and committing would act on the wrong window.
final class OverlayPanel: NSPanel {
    let switcherView = SwitcherView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .screenSaver // above fullscreen windows
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.masksToBounds = true
        contentView = effect

        switcherView.autoresizingMask = [.width, .height]
        effect.addSubview(switcherView)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(tiles: [Tile], selected: Int, desktopSelection: [UInt64: Int]) {
        switcherView.tiles = tiles
        switcherView.selected = selected
        switcherView.desktopSelection = desktopSelection

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = switcherView.layoutSize(maxWidth: screen.frame.width - 90)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.midY - size.height / 2)
        setFrame(NSRect(origin: origin, size: size), display: true)
        switcherView.frame = NSRect(origin: .zero, size: size)
        switcherView.needsDisplay = true
        orderFrontRegardless()
    }

    func refresh(selected: Int, desktopSelection: [UInt64: Int]) {
        switcherView.selected = selected
        switcherView.desktopSelection = desktopSelection
        switcherView.needsDisplay = true
    }

    func dismiss() {
        orderOut(nil)
    }
}
