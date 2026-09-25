import Cocoa

/// Draws the switcher row: one tile per fullscreen window, one per desktop Space.
final class SwitcherView: NSView {
    var tiles: [Tile] = []
    var selected = 0
    /// Which window inside a desktop tile is picked, keyed by Space id.
    var desktopSelection: [UInt64: Int] = [:]
    var thumbnails: [CGWindowID: NSImage] = [:]
    var desktopPreviews: [UInt64: NSImage] = [:]

    /// Called when the mouse picks a tile (and optionally an icon within a desktop tile).
    var onHover: ((Int, Int?) -> Void)?
    var onClick: ((Int, Int?) -> Void)?

    static let tileHeight: CGFloat = 190
    static let gap: CGFloat = 16
    static let padding: CGFloat = 24
    static let labelHeight: CGFloat = 30
    static let corner: CGFloat = 12
    /// Room under the icon for the number you can press to jump straight to a tile.
    static let badgeHeight: CGFloat = 20

    private(set) var tileWidth: CGFloat = 300

    /// Tiles shrink rather than overflow when there are a lot of windows, the same way the
    /// system switcher shrinks its icons.
    func layoutSize(maxWidth: CGFloat) -> NSSize {
        let count = max(tiles.count, 1)
        tileWidth = 300
        var width = Self.padding * 2 + CGFloat(count) * tileWidth + CGFloat(count - 1) * Self.gap
        if width > maxWidth {
            let available = maxWidth - Self.padding * 2 - CGFloat(count - 1) * Self.gap
            tileWidth = max(96, available / CGFloat(count))
            width = Self.padding * 2 + CGFloat(count) * tileWidth + CGFloat(count - 1) * Self.gap
        }
        return NSSize(width: width,
                      height: Self.padding * 2 + Self.tileHeight + Self.labelHeight)
    }

    /// Where a tile sits. Drawing and hit testing both go through this and `iconRects`, so the
    /// two can't disagree about what the user is pointing at.
    func tileRect(_ index: Int) -> NSRect {
        NSRect(x: Self.padding + CGFloat(index) * (tileWidth + Self.gap),
               y: Self.padding + Self.labelHeight,
               width: tileWidth,
               height: Self.tileHeight)
    }

    /// Icon positions inside a desktop tile, laid out as a centered grid.
    func iconRects(count: Int, in rect: NSRect) -> [NSRect] {
        guard count > 0 else { return [] }
        var iconSize: CGFloat = min(52, rect.width / 5.2)
        let spacing: CGFloat = 9
        var perRow = 1, rows = 1
        var gridHeight: CGFloat = 0
        // Icons shrink only when the grid would otherwise spill out of the tile, which it did
        // from 13 apps up at full width, drawing over the number badge and the label. Any grid
        // that already fits keeps exactly the size it always had.
        repeat {
            perRow = max(1, min(count, Int((rect.width - 16) / (iconSize + spacing))))
            rows = Int(ceil(Double(count) / Double(perRow)))
            gridHeight = CGFloat(rows) * iconSize + CGFloat(rows - 1) * spacing
            if gridHeight <= rect.height || iconSize <= 6 { break }
            iconSize -= 1
        } while true

        var rects: [NSRect] = []
        for index in 0..<count {
            let row = index / perRow
            let column = index % perRow
            let itemsInRow = min(perRow, count - row * perRow)
            let rowWidth = CGFloat(itemsInRow) * iconSize + CGFloat(itemsInRow - 1) * spacing
            let x = rect.midX - rowWidth / 2 + CGFloat(column) * (iconSize + spacing)
            let y = rect.midY + gridHeight / 2 - CGFloat(row + 1) * iconSize - CGFloat(row) * spacing
            rects.append(NSRect(x: x, y: y, width: iconSize, height: iconSize))
        }
        return rects
    }

    /// The window that would be activated right now.
    func currentWindow() -> WindowInfo? {
        guard selected < tiles.count else { return nil }
        switch tiles[selected] {
        case .window(_, let window):
            return window
        case .desktop(let space, let windows):
            let index = desktopSelection[space.id] ?? 0
            return windows.indices.contains(index) ? windows[index] : windows.first
        }
    }

    override var isFlipped: Bool { false }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .activeAlways because the panel never becomes key, so the usual
        // mouse-moved delivery to the key window would never reach us.
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    /// Which tile, and which icon inside it, a point falls on.
    func hit(_ point: NSPoint) -> (tile: Int, icon: Int?)? {
        for index in tiles.indices {
            let rect = tileRect(index)
            guard rect.insetBy(dx: -Self.gap / 2, dy: -8).contains(point) else { continue }
            if case .desktop(_, let windows) = tiles[index] {
                let rects = iconRects(count: windows.count, in: rect)
                for (iconIndex, iconRect) in rects.enumerated()
                where iconRect.insetBy(dx: -4, dy: -4).contains(point) {
                    return (index, iconIndex)
                }
            }
            return (index, nil)
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard let hit = hit(convert(event.locationInWindow, from: nil)) else { return }
        onHover?(hit.tile, hit.icon)
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let hit = hit(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(hit.tile, hit.icon)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high

        for (index, tile) in tiles.enumerated() {
            let rect = tileRect(index)
            if index == selected { drawSelection(around: rect) }
            drawThumbnail(for: tile, in: rect)
            switch tile {
            case .window(_, let window):
                drawAppIcon(window.icon, at: rect)
            case .desktop(let space, let windows):
                // No single app icon here: the grid already shows every app on this desktop,
                // and drawing one on top of it just obscured the grid.
                drawIconGrid(windows,
                             in: rect,
                             selectedIndex: index == selected ? (desktopSelection[space.id] ?? 0) : -1)
            }
            drawNumber(index, in: rect)
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

        if let image = image, image.size.width > 0, image.size.height > 0 {
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

    private func drawAppIcon(_ icon: NSImage?, at rect: NSRect) {
        guard let icon = icon else { return }
        let size: CGFloat = min(56, rect.width * 0.22)
        let iconRect = NSRect(x: rect.minX + 10,
                              y: rect.minY + 10 + Self.badgeHeight,
                              width: size,
                              height: size)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        icon.draw(in: iconRect)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// Desktop tiles show one icon per app on that Space, in the order the arrow keys step
    /// through them, laid over the desktop preview.
    private func drawIconGrid(_ windows: [WindowInfo], in rect: NSRect, selectedIndex: Int) {
        let rects = iconRects(count: windows.count, in: rect)
        for (index, window) in windows.enumerated() {
            let iconRect = rects[index]
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

    /// The number that jumps straight to this tile, sitting under the app icon.
    private func drawNumber(_ index: Int, in rect: NSRect) {
        guard index < 9 else { return } // only 1-9 are reachable from the keyboard
        let text = "\(index + 1)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let iconWidth = min(56, rect.width * 0.22)
        let centre = rect.minX + 10 + iconWidth / 2
        let box = NSRect(x: centre - max(size.width, 12) / 2 - 6,
                         y: rect.minY + 6,
                         width: max(size.width, 12) + 12,
                         height: Self.badgeHeight - 4)
        let pill = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        NSColor.black.withAlphaComponent(0.7).setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        (text as NSString).draw(at: NSPoint(x: centre - size.width / 2, y: box.minY + 0.5),
                                withAttributes: [.font: font,
                                                 .foregroundColor: NSColor.white.withAlphaComponent(0.95)])
    }

    private func drawLabel() {
        guard let window = currentWindow() else { return }
        let text = window.title.isEmpty ? window.appName : "\(window.appName) - \(window.title)"
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
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

/// Full-screen backdrop. It exists to swallow mouse events: without it, clicks and drags land
/// in whatever app is underneath, so dragging across the switcher would select text in the
/// window behind it.
final class ShieldView: NSView {
    var onClickOutside: (() -> Void)?
    var hudRect: NSRect = .zero

    override func mouseUp(with event: NSEvent) {
        if !hudRect.contains(convert(event.locationInWindow, from: nil)) { onClickOutside?() }
    }

    // Swallow the rest so nothing reaches the app below.
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

/// The floating panel. It must never take focus, or the app being switched away from would stop
/// being frontmost and committing would act on the wrong window.
final class OverlayPanel: NSPanel {
    let switcherView = SwitcherView()
    private let shield = ShieldView()
    private let effect = NSVisualEffectView()

    var onCancel: (() -> Void)?

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
        hasShadow = false
        hidesOnDeactivate = false
        // No fade. By default AppKit fades a panel out over about 40ms when it is ordered out,
        // measured by sampling the screen, so after Cmd was released the switcher lingered on
        // screen while the switch it had just asked for was already under way. Committing
        // relies on the overlay being gone within one run-loop turn, and without the fade it is.
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.masksToBounds = true

        shield.addSubview(effect)
        shield.addSubview(switcherView)
        shield.onClickOutside = { [weak self] in self?.onCancel?() }
        contentView = shield
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Re-applies the traits that let the panel appear over every Space.
    ///
    /// Set once at construction they can be lost later, and a panel that has become tied to one
    /// Space is invisible everywhere else while still reporting itself as a perfectly healthy,
    /// visible, full-screen window. Cheap enough to simply assert again on every open.
    func reassertSpaceBehavior() {
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    func present(tiles: [Tile], selected: Int, desktopSelection: [UInt64: Int]) {
        reassertSpaceBehavior()
        switcherView.tiles = tiles
        switcherView.selected = selected
        switcherView.desktopSelection = desktopSelection

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let hudSize = switcherView.layoutSize(maxWidth: screen.frame.width - 90)

        // The panel covers the whole screen so no mouse event can slip past it; the visible
        // HUD is just a subview in the middle.
        setFrame(screen.frame, display: true)
        let hudRect = NSRect(x: (screen.frame.width - hudSize.width) / 2,
                             y: (screen.frame.height - hudSize.height) / 2,
                             width: hudSize.width,
                             height: hudSize.height)
        shield.frame = NSRect(origin: .zero, size: screen.frame.size)
        shield.hudRect = hudRect
        effect.frame = hudRect
        switcherView.frame = hudRect
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
